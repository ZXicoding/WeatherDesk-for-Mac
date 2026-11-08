import AppKit
import QuartzCore

/// 一块桌面级画布。
///
/// 真实感来自四件事，而不是更多的图形：
/// 1. 形状用分形噪声烘焙的遮罩（云的蓬松边缘、雾的不均匀密度），而不是圆角矩形；
/// 2. 光照分层（天空渐变 / 地平线辉光 / 跟随太阳的大气散射 / 云顶亮云底暗 / 暗角）；
/// 3. 景深分层（远中近三层的尺寸、速度、透明度、模糊程度都不同）；
/// 4. 每个个体的速度、相位、摆幅都带扰动，避免整排粒子齐步走。
///
/// 全部由 CALayer + CAAnimation 交给 GPU 合成，逐帧不占 CPU、不接收鼠标事件。
final class SkyView: NSView {

    // 图层栈（由下至上）
    /// 实景模式（方案一）的照片底图：位于最底层，开启时顶替 sky 渐变
    private let sceneLayer = CALayer()
    private let sky = CAGradientLayer()
    private let horizon = CAGradientLayer()
    private let twilightGlow = CAGradientLayer()
    private let lightDome = CAGradientLayer()
    private let scatter = CAGradientLayer()
    private let starHost = CALayer()
    /// 由真实星表在观测时刻绘制的星图（位图）。跨文件扩展需要访问，故为 internal
    let starField = CALayer()
    let twinkleHost = CALayer()
    let labelHost = CALayer()
    let meteorHost = CALayer()
    private let bodyGlow = CAGradientLayer()
    private let bodyLayer = CALayer()
    private let sunDisc = CAGradientLayer()
    private let moonDim = CALayer()
    private let moonBright = CALayer()
    private let moonPhaseMask = CAShapeLayer()
    private let cloudHost = CALayer()
    private let fogHost = CALayer()
    private let particleHost = CALayer()
    private let vignette = CAGradientLayer()
    private let flash = CALayer()
    private let boltHost = CALayer()
    private let infoHost = CALayer()

    private var installed = false
    var weather: Weather?
    var meteorScheduled = false
    private var signature = ""
    private var lastSize: CGSize = .zero
    private var lightningWork: DispatchWorkItem?

    /// 仅供离屏预览工具：生成效果图时隐藏角标，且不动用户的偏好设置
    var hidesInfoForPreview = false
    /// 预览用：固定一个好看的月相；nil 时按真实月相显示
    var previewMoonPhase: Double?
    /// 预览用：强制显示 / 隐藏星图标注，不改动用户偏好
    var forceStarLabels: Bool?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .never
        install()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        install()
        applyFrames()
        if let w = weather { apply(weather: w, animated: false) }
    }

    /// 纯 layer-backed 视图不保证走 layout()，安装时也要主动铺一次尺寸
    private func applyFrames() {
        guard installed, bounds.width > 1, let root = layer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        root.frame = bounds
        for l in [sceneLayer, sky, horizon, twilightGlow, lightDome, scatter, starHost,
                  starField, twinkleHost, labelHost, meteorHost,
                  cloudHost, fogHost, particleHost,
                  vignette, flash, boltHost, infoHost] { l.frame = bounds }
        CATransaction.commit()
    }

    private func install() {
        guard !installed, let root = layer else { return }
        installed = true
        root.backgroundColor = NSColor.clear.cgColor

        // y=1 是屏幕顶部
        sky.startPoint = CGPoint(x: 0.5, y: 1)
        sky.endPoint = CGPoint(x: 0.5, y: 0)
        sky.locations = [0, 0.30, 0.58, 0.80, 1]
        sky.colors = [NSColor.black.cgColor, NSColor.black.cgColor, NSColor.black.cgColor,
                      NSColor.black.cgColor, NSColor.black.cgColor]

        horizon.startPoint = CGPoint(x: 0.5, y: 0)
        horizon.endPoint = CGPoint(x: 0.5, y: 1)
        horizon.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        horizon.opacity = 0

        for g in [scatter, bodyGlow, sunDisc, twilightGlow, vignette] {
            g.type = .radial
            g.startPoint = CGPoint(x: 0.5, y: 0.5)
            g.endPoint = CGPoint(x: 1, y: 1)
        }
        twilightGlow.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        twilightGlow.opacity = 0
        lightDome.startPoint = CGPoint(x: 0.5, y: 0)
        lightDome.endPoint = CGPoint(x: 0.5, y: 1)
        lightDome.colors = [NSColor(calibratedRed: 0.95, green: 0.58, blue: 0.34, alpha: 0.30).cgColor,
                            NSColor.clear.cgColor]
        lightDome.locations = [0, 1] as [NSNumber]
        lightDome.opacity = 0

        starField.contentsGravity = .resize
        starField.masksToBounds = false
        starField.contentsScale = 1
        twinkleHost.masksToBounds = false
        labelHost.masksToBounds = false
        meteorHost.masksToBounds = true

        scatter.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        scatter.opacity = 0
        bodyGlow.colors = [NSColor.clear.cgColor, NSColor.clear.cgColor]
        bodyGlow.opacity = 0
        sunDisc.colors = [NSColor.white.cgColor, NSColor.white.withAlphaComponent(0).cgColor]
        sunDisc.locations = [0, 1] as [NSNumber]

        vignette.colors = [NSColor.clear.cgColor,
                           NSColor(calibratedWhite: 0, alpha: 0.20).cgColor]
        vignette.locations = [0, 1] as [NSNumber]

        moonDim.contents = TextureFactory.moonSurface
        moonBright.contents = TextureFactory.moonSurface
        moonDim.opacity = 0.14   // 新月只留极淡的地球反照，不该出现一整个灰盘
        moonPhaseMask.fillColor = NSColor.white.cgColor
        moonBright.mask = moonPhaseMask
        bodyLayer.addSublayer(sunDisc)
        bodyLayer.addSublayer(moonDim)
        bodyLayer.addSublayer(moonBright)

        flash.backgroundColor = NSColor(calibratedRed: 0.84, green: 0.91, blue: 1.0, alpha: 1).cgColor
        flash.opacity = 0
        boltHost.opacity = 0
        particleHost.masksToBounds = true

        sceneLayer.contentsGravity = .resizeAspectFill
        sceneLayer.masksToBounds = true
        sceneLayer.isHidden = true
        sceneLayer.opacity = 0

        for l in [sceneLayer, sky, horizon, lightDome, twilightGlow, scatter, starHost, meteorHost,
                  bodyGlow, bodyLayer, cloudHost, fogHost, particleHost,
                  vignette, flash, boltHost, infoHost] {
            root.addSublayer(l)
        }
        starHost.addSublayer(starField)
        starHost.addSublayer(twinkleHost)
        starHost.addSublayer(labelHost)
        applyFrames()
        // 实时摄像头抓到新帧时只替换底图内容，不重建云 / 雨 / 雪粒子层
        NotificationCenter.default.addObserver(
            self, selector: #selector(liveCamFrameChanged),
            name: .wdLiveCamFrame, object: nil)
    }

    @objc private func liveCamFrameChanged() {
        guard Settings.shared.backgroundMode != .sky else { return }
        guard Settings.shared.liveCamEnabled else {
            // 关掉实时摄像头：重新按天气 / 时段选回静态底图
            if let w = weather { apply(weather: w, animated: false) }
            return
        }
        if let img = LiveCamFeed.shared.currentFrame {
            CATransaction.begin()
            CATransaction.setAnimationDuration(1.1)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
            sceneLayer.contents = img
            sceneLayer.isHidden = false
            sceneLayer.opacity = Float(Settings.shared.skyOpacity)
            CATransaction.commit()
        } else if let w = weather {
            // 附近摄像头全不可用：无缝回退到静态照片，桌面不会空白
            apply(weather: w, animated: false)
        }
    }

    override func layout() {
        super.layout()
        let s = bounds.size
        guard s.width > 1, s.height > 1, s != lastSize else { return }
        lastSize = s
        applyFrames()
        signature = ""
        if let w = weather { apply(weather: w, animated: false) }
    }

    // MARK: 应用一次天气状态

    func apply(weather w: Weather, animated: Bool) {
        install()
        guard installed, bounds.width > 1 else { return }
        weather = w
        // 第一次 apply 就启动实时帧供给；内部按地点去重，不会因 20 秒的太阳刷新反复重启
        LiveCamFeed.shared.ensure(place: w.place)
        // 真实数据：相位 / 星空 / 暖色都由太阳真实地平高度 + 升落趋势实时决定，
        // 日出日落那一刻画面就切换，不再等天气接口下一次刷新。
        // 演示 / 预览：仍用人工构造的日出日落插值，保证白天也能看到完整效果。
        let st: SkyState
        if w.simulated {
            st = w.sky()
        } else {
            st = Astronomy.skyState(date: Date(), place: w.place)
        }
        // 演示 / 预览用的是人工构造的日出日落，星图改用「当天 22:00 的真实星空」，
        // 这样白天打开预览也能看到今夜实际会出现的星座，而不是一片空白。
        let astroDate = (w.simulated && st.stars > 0) ? Self.simulatedNightDate(for: w) : Date()
        let frame = Astronomy.frame(date: astroDate, place: w.place)
        let pal = Palette.make(state: st, condition: w.condition, cloudCover: w.cloudCover)
        let target = Self.cloudTarget(w)

        let packSig = Settings.shared.autoBiome
            ? (Settings.forcedBiomePack ?? EcoScene.biome(for: w).photoPack) : "off"
        let structSig = [w.condition.rawValue, String(target),
                         String(Int(Settings.shared.intensity * 10)),
                         String(Int(bounds.width)), String(Int(bounds.height)),
                         Settings.shared.backgroundMode.rawValue, packSig]
            .joined(separator: "|")
        let rebuild = structSig != signature
        signature = structSig

        // 颜色用 2.2 秒过渡；天体位置用 20 秒匀速动画，与时钟推进周期一致
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(2.2)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeInEaseOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        sky.colors = [pal.top.cgColor,
                      pal.top.mixed(pal.mid, 0.55).cgColor,
                      pal.mid.cgColor,
                      pal.mid.mixed(pal.bottom, 0.58).cgColor,
                      pal.bottom.cgColor]
        // 照片实景模式：真实照片做底，云 / 雨 / 雪 / 雾 / 闪电继续作为动画层叠加；
        // 程序化天空渐变、日月与星图让位给照片自带的光照。找不到素材时自动回退。
        // 切换背景来源时 structSig 变化，会连带重建全部动画层，不留旧粒子。
        let mode = Settings.shared.backgroundMode
        let scene = mode == .sky ? nil : Self.sceneImage(for: w, st: st, size: bounds.size)
        let cloudVeil = pow(max(0, 1 - Double(w.cloudCover) / 100), 1.15)
        // 实时数据下星点可见度直接由真实的暮光暗度驱动，太阳落山即亮起
        let night = w.simulated ? st.stars : frame.darkness
        if let img = scene {
            CATransaction.setDisableActions(true)
            sceneLayer.contents = img
            sceneLayer.isHidden = false
            sceneLayer.opacity = Float(Settings.shared.skyOpacity)
            sky.opacity = 0
            starHost.opacity = 0
        } else {
            sceneLayer.isHidden = true
            sceneLayer.opacity = 0
            sky.opacity = Float(Settings.shared.skyOpacity)
            starHost.opacity = Float(night * cloudVeil)
        }
        applyLighting(st: st, pal: pal, w: w, frame: frame)
        if scene != nil {
            // 实景模式下大气光照层全部退场（照片自带光照），雾幕与角标保留
            horizon.opacity = 0
            twilightGlow.opacity = 0
            lightDome.opacity = 0
            scatter.opacity = 0
        }
        CATransaction.commit()

        CATransaction.begin()
        if scene != nil {
            CATransaction.setDisableActions(true)
            bodyLayer.opacity = 0
            bodyGlow.opacity = 0
        } else {
            if animated {
                CATransaction.setAnimationDuration(20)
                CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .linear))
            } else {
                CATransaction.setDisableActions(true)
            }
            positionBody(st: st, pal: pal, w: w, frame: frame)
        }
        CATransaction.commit()

        if rebuild {
            rebuildClouds(count: target, pal: pal, w: w)
            rebuildFog(w: w)
            rebuildParticles(w: w)
            scheduleLightning(w.condition.isThunder)
        } else {
            retintClouds(pal: pal, st: st, w: w, animated: animated)
        }
        let starCount = updateStarField(frame: frame)
        scheduleMeteor()
        updateInfo(w: w, frame: frame, st: st, starCount: starCount)
    }

    private static func cloudTarget(_ w: Weather) -> Int {
        min(12, w.condition.cloudBase + Int(Double(w.cloudCover) / 20.0))
    }

    // MARK: 背景底图（当地生态 / 用户照片包 / 内置照片兜底）

    /// 缓存 key 必须带「目录 + 图名」，图名里含 2 小时档位。
    /// 旧版只用图名且夜档覆盖十几个小时，换城市不换图、深夜跟下午同图都出在这里。
    /// 档位边界与换城市时由 DesktopController 清缓存，用户中途换照片也能生效。
    private static var photoCache: [String: CGImage] = [:]

    static func invalidateScenes() {
        photoCache.removeAll()
        EcoScene.invalidate()
    }

    /// 背景优先级：
    /// photo = 公开实时摄像头帧（开启时） > 2 小时档位图 > 旧版天气/时段图
    /// eco   = 该地点专属照片包 > 现场生成的当地生态 > Bundle 内置照片兜底
    /// sky   = 不使用底图，回到纯程序化天空
    ///
    /// 2 小时档位图与旧图分开两轮查找：先让 12 档图跨「地点目录 / 生态包 / default / 内置」
    /// 全部层级优先命中，再退回旧命名。这样即使用户自建目录里只有旧的 5 张，
    /// 内置的 12 档图也不会被旧图顶掉。
    private static func sceneImage(for w: Weather, st: SkyState, size: CGSize) -> CGImage? {
        switch Settings.shared.backgroundMode {
        case .photo:
            // 实时摄像头优先：换 IP 后 update(place:) 会换掉当前摄像头并清空旧帧，
            // 抓到新帧前这里自动回退静态照片，不会出现旧地点的画面或黑屏。
            if Settings.shared.liveCamEnabled,
               let frame = LiveCamFeed.shared.currentFrame { return frame }
            if Settings.shared.twoHourScenes,
               let img = lookup(slotNames(for: w), w: w) { return img }
            return lookup(legacyNames(for: w, st: st), w: w)
        case .eco:
            if let custom = customPhoto(for: w, st: st, includeDefault: false) { return custom }
            return EcoScene.image(for: w, st: st, size: size) ?? bundlePhoto(for: w, st: st)
        case .sky:
            return nil
        }
    }

    /// 当前 2 小时档位的候选文件名。天气专属覆盖（rain / snow）优先，
    /// 其次才是该档主图；内置没有天气覆盖时，天气交给粒子层与雾幕表达。
    private static func slotNames(for w: Weather) -> [String] {
        let tz = SceneClock.timeZone(w)
        let base = SceneClock.name(SceneClock.slot(date: Date(), timeZone: tz))
        if let tag = weatherTag(w.condition) { return ["\(base)-\(tag)", base] }
        return [base]
    }

    /// 兼容旧版 5 张命名，同时作为 12 档素材缺失时的兜底链。
    private static func legacyNames(for w: Weather, st: SkyState) -> [String] {
        switch w.condition {
        case .drizzle, .rain, .heavyRain, .thunder, .fog:
            return ["scene-rain", "scene-clear"]
        case .snow, .sleet:
            return ["scene-snow", "scene-rain", "scene-clear"]
        case .clear, .partlyCloudy, .cloudy, .overcast:
            switch st.phase {
            case .night:       return ["scene-night", "scene-clear"]
            case .dawn, .dusk: return ["scene-sunset", "scene-night", "scene-clear"]
            case .day:         return ["scene-clear"]
            }
        }
    }

    private static func weatherTag(_ c: Condition) -> String? {
        switch c {
        case .drizzle, .rain, .heavyRain, .thunder, .fog: return "rain"
        case .snow, .sleet:                              return "snow"
        default:                                         return nil
        }
    }

    /// 精确匹配当前地点的目录别名（不含 default —— 它是通用兜底，
    /// 若把它也算「地点专属」，生态模式会被通用照片永久顶掉）
    private static func localFolders(_ p: Place) -> [String] {
        var out: [String] = []
        for s in ["\(p.region)-\(p.name)", p.name, p.region] {
            let t = sanitized(s)
            if !t.isEmpty, !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// 按「文件名优先级 × 目录优先级」找第一张存在的照片。
    /// 目录顺序：该地点专属 → 生态带包（开启时）→ 用户 default → App 内置。
    /// 每个层级内部先试完整的候选名链，所以时段图齐备时不会被旧图顶掉。
    private static func lookup(_ names: [String], w: Weather,
                               includeDefault: Bool = true,
                               includeBiome: Bool = true,
                               includeBundle: Bool = true) -> CGImage? {
        guard !names.isEmpty else { return nil }
        if let img = images(names, in: localFolders(w.place), root: scenesRoot) { return img }
        if includeBiome, Settings.shared.autoBiome {
            let pack = Settings.forcedBiomePack ?? EcoScene.biome(for: w).photoPack
            if EcoBiome.allPhotoPacks.contains(pack),
               let res = Bundle.main.resourceURL,
               let img = images(names, in: ["biomes/\(pack)"], root: res) { return img }
        }
        if includeDefault,
           let img = images(names, in: ["default"], root: scenesRoot) { return img }
        if includeBundle, let res = Bundle.main.resourceURL,
           let img = images(names, in: [""], root: res) { return img }
        return nil
    }

    private static func images(_ names: [String], in folders: [String],
                               root: URL) -> CGImage? {
        for folder in folders {
            let dir = folder.isEmpty ? root : root.appendingPathComponent(folder, isDirectory: true)
            for name in names {
                let key = "\(dir.path)/\(name)"
                if let hit = photoCache[key] { return hit }
                let url = dir.appendingPathComponent("\(name).jpg")
                // 不做「未命中」缓存：用户随时可能往目录里放新照片，下次 apply 就该生效
                if let img = loadImage(at: url) {
                    photoCache[key] = img
                    return img
                }
            }
        }
        return nil
    }

    /// eco 模式沿用旧命名：地点专属照片 > 内置兜底
    private static func customPhoto(for w: Weather, st: SkyState,
                                    includeDefault: Bool) -> CGImage? {
        lookup(legacyNames(for: w, st: st), w: w, includeDefault: includeDefault,
               includeBiome: false, includeBundle: false)
    }

    private static func bundlePhoto(for w: Weather, st: SkyState) -> CGImage? {
        lookup(legacyNames(for: w, st: st), w: w, includeDefault: false,
               includeBiome: false, includeBundle: true)
    }

    private static var scenesRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("天气桌面/scenes", isDirectory: true)
    }

    /// 文件夹名里不允许的字符替换掉
    private static func sanitized(_ s: String) -> String {
        s.replacingOccurrences(of: "/", with: "_")
         .replacingOccurrences(of: ":", with: "_")
         .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadImage(at url: URL) -> CGImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let img = NSImage(contentsOf: url)?
                  .cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return img
    }

    /// 预览用：当天 22:00（当地时区）的真实星空
    private static func simulatedNightDate(for w: Weather) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = w.localTimeZone
        let parts = cal.dateComponents([.year, .month, .day], from: Date())
        let midnight = cal.date(from: parts) ?? Date()
        return cal.date(byAdding: .hour, value: 22, to: midnight) ?? Date()
    }

    // MARK: 大气光照

    private func applyLighting(st: SkyState, pal: Palette, w: Weather, frame: SkyFrame) {
        let W = bounds.width, H = bounds.height
        let warm = CGFloat(st.warmth)

        // 地平线辉光：日出日落是暖橘，夜里是残留的冷蓝
        let horizonColor: NSColor = st.isSun
            ? NSColor.rgb(1.0, 0.60, 0.34).mixed(.rgb(1.0, 0.84, 0.58), 1 - warm)
            : NSColor.rgb(0.30, 0.40, 0.66)
        horizon.frame = CGRect(x: 0, y: 0, width: W, height: H * 0.62)
        horizon.colors = [horizonColor.withAlphaComponent(0.72).cgColor,
                          horizonColor.withAlphaComponent(0).cgColor]
        let twilight: CGFloat = (st.phase == .dawn || st.phase == .dusk) ? 1 : 0
        horizon.opacity = Float((0.10 + warm * 0.62) * (st.isSun ? 1 : 0.38) * (0.35 + twilight * 0.65))

        // 跟随太阳 / 月亮的大范围散射，让天空不只是「一条渐变」
        let halo = pal.body.mixed(pal.bottom, st.isSun ? 0.15 : 0.45)
        scatter.colors = [halo.withAlphaComponent(st.isSun ? 0.56 : 0.16).cgColor,
                          halo.withAlphaComponent(0).cgColor]
        let overcast = w.condition == .overcast || w.condition == .heavyRain ||
                       w.condition == .thunder || w.condition.isFoggy
        let base: CGFloat = st.isSun ? 0.30 : 0.16
        scatter.opacity = Float(max(0.04, (base + warm * 0.32 + twilight * 0.16)
                                    * (overcast ? 0.35 : 1)))

        // 连续曙暮光：太阳从 +6° 沉到 -18° 的过程中，地平线附近的暖色辉光
        // 平滑地生起又褪去，而不是在 dusk → night 的瞬间整片跳色。
        let sunAlt = frame.sun.altDeg
        let glow = exp(-pow((sunAlt + 2.5) / 7.5, 2))
        let sp = frame.project(frame.sun, size: bounds.size)
        let sx = min(0.95, max(0.05, CGFloat(sp?.x ?? 0.5)))
        let sy = min(0.58, max(0.0, CGFloat(sp?.y ?? 0.02)))
        let gw = W * 1.25, gh = H * 1.05
        twilightGlow.frame = CGRect(x: sx * W - gw / 2, y: sy * H - gh * 0.42,
                                    width: gw, height: gh)
        let gold = min(1, max(0, (sunAlt + 8) / 16))
        let glowColor = NSColor.rgb(1.0, 0.42, 0.20).mixed(.rgb(1.0, 0.78, 0.50), CGFloat(gold))
        twilightGlow.colors = [glowColor.withAlphaComponent(0.62).cgColor,
                               glowColor.withAlphaComponent(0).cgColor]
        twilightGlow.opacity = Float(min(0.92, 0.78 * glow
                                         * (1 + Double(w.cloudCover) / 100 * 0.45)))

        // 城市光污染：夜里地平线上方一层极淡的暖橙，阴天被云反射后更明显
        lightDome.frame = CGRect(x: 0, y: 0, width: W, height: H * 0.48)
        lightDome.opacity = Float(frame.darkness
                                  * (0.15 + Double(w.cloudCover) / 100 * 0.55))
    }

    // MARK: 日 / 月

    private func positionBody(st: SkyState, pal: Palette, w: Weather, frame: SkyFrame) {
        let W = bounds.width, H = bounds.height
        // 月亮无论实时还是演示，都用与恒星同一套天文坐标：今晚没升起就不画。
        // 太阳在演示 / 预览里仍用日出日落插值，保证白天也能看到完整的日落效果。
        let real = !w.simulated
        let body = st.isSun ? frame.sun : frame.moon
        var x = st.x * W, y = st.y * H
        var visible = true
        if real || !st.isSun {
            if body.altDeg < -1.2 {
                visible = false       // 月亮尚未升起或已经落下：真实夜空里就不该挂一个月亮
            } else if let p = frame.project(body, size: bounds.size) {
                visible = p.x > -0.08 && p.x < 1.08 && p.y > -0.08 && p.y < 1.08
                // 盛夏正午或偏东偏西的日落会越过窗口边缘，贴边保留日轮与散射辉光
                x = min(W * 0.95, max(W * 0.05, p.x * W))
                y = min(H * 0.92, max(H * 0.06, p.y * H))
            } else {
                visible = false
            }
        }
        // 朔月前后只剩地球反照，肉眼看不出圆盘，不该挂一个灰圆
        if !st.isSun && frame.moonIllumination < 0.035 { visible = false }
        // 贴近地平线时日轮视觉上更大（大气折射 + 与地景对比）
        let r = min(W, H) * (st.isSun ? (0.052 + CGFloat(st.warmth) * 0.026) : 0.040)
        let R = r * (st.isSun ? 11 : 7)

        let hidden = w.condition == .overcast || w.condition == .heavyRain ||
                     w.condition == .thunder || w.condition.isFoggy
        // 阴雨天天体被云层彻底吃掉，只留一团极淡的散射光；不该挂一个清楚的圆盘
        let alpha: CGFloat = !visible ? 0
            : hidden ? 0.04 : (w.condition.isRainy || w.condition.isSnowy ? 0.07 : 0.98)

        // 子层结构 / 颜色立即生效；天体位置交给调用方的慢速匀速动画
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        bodyLayer.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
        // 大气折射：贴近地平线时日轮被纵向压扁
        bodyLayer.transform = CATransform3DMakeScale(1, 1 - CGFloat(st.warmth) * 0.12, 1)

        let inset = bodyLayer.bounds
        sunDisc.frame = inset
        moonDim.frame = inset
        moonBright.frame = inset
        moonPhaseMask.frame = inset

        sunDisc.isHidden = !st.isSun
        moonDim.isHidden = st.isSun
        moonBright.isHidden = st.isSun
        // 暗面亮度随月相变化：新月不该出现一整块灰盘
        moonDim.opacity = 0.05 + Float(frame.moonIllumination) * 0.12
        bodyLayer.opacity = Float(alpha)

        var discColor = pal.body
        if st.isSun {
            // 日出日落时把日轮压成明显的橙红，而不是一颗发白的灯
            let twilight: CGFloat = (st.phase == .dawn || st.phase == .dusk)
                ? 0.35 + CGFloat(st.warmth) * 0.65 : 0
            discColor = pal.body.mixed(.rgb(1.0, 0.38, 0.14), twilight * 0.60)
            let core = NSColor.white.mixed(discColor, 0.16 + twilight * 0.34)
            sunDisc.colors = [core.cgColor,
                              discColor.withAlphaComponent(0.98).cgColor,
                              discColor.withAlphaComponent(0).cgColor]
            sunDisc.locations = [0, 0.78, 1] as [NSNumber]
        } else {
            moonPhaseMask.path = Self.moonPhasePath(
                center: CGPoint(x: r, y: r), radius: r,
                phase: previewMoonPhase ?? frame.moonPhase)
        }

        bodyGlow.colors = [discColor.withAlphaComponent(st.isSun ? 0.52 : 0.28).cgColor,
                           discColor.withAlphaComponent(0).cgColor]
        bodyGlow.opacity = Float(alpha * (st.isSun ? 0.85 : 0.42))
        CATransaction.commit()

        bodyLayer.position = CGPoint(x: x, y: y)
        bodyGlow.frame = CGRect(x: x - R, y: y - R, width: R * 2, height: R * 2)
        let S = max(W, H) * 0.62
        scatter.frame = CGRect(x: x - S, y: y - S * 0.7, width: S * 2, height: S * 1.4)
    }

    /// 参考新月 2000-01-06 18:14 UTC，朔望月 29.5306 天；返回 0（朔）…0.5（望）…1
    private static func currentMoonPhase() -> Double {
        let ref: TimeInterval = 947182440
        let p = (Date().timeIntervalSince1970 - ref) / 86400 / 29.530588853
        return p - floor(p)
    }

    /// 月相亮区：外轮廓固定右半圆，内弧是宽度随月相变化的半椭圆；下半月整体镜像
    private static func moonPhasePath(center c: CGPoint, radius r: CGFloat, phase: Double) -> CGPath {
        let f = (1 - cos(2 * Double.pi * phase)) / 2        // 照亮比例 0…1
        let rx = r * CGFloat(1 - 2 * f)
        let mirror = phase > 0.5 ? CGAffineTransform(scaleX: -1, y: 1) : .identity
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: -r))
        p.addArc(center: .zero, radius: r,
                 startAngle: -Double.pi / 2, endAngle: Double.pi / 2, clockwise: false)
        p.addCurve(to: CGPoint(x: 0, y: -r),
                   control1: CGPoint(x: rx * 1.34, y: r),
                   control2: CGPoint(x: rx * 1.34, y: -r))
        p.closeSubpath()
        var t = CGAffineTransform(translationX: c.x, y: c.y)
        if phase > 0.5 { t = mirror.concatenating(t) }
        return p.copy(using: &t) ?? p
    }

    // MARK: 星空
    // 真实星表的绘制在 SkyStars.swift（extension SkyView）里：
    // 按观测地的经纬度与当前恒星时，把依巴谷星表的每颗星投影到同一片天空。

    /// 稳定的伪随机 0…1，保证多块屏幕的星空一致，也不依赖种子状态
    private static func rand(_ n: Int) -> Double {
        var h = UInt32(truncatingIfNeeded: n &* 2654435761) ^ 0x9E3779B9
        h = h &* 1664525 &+ 1013904223
        h ^= h >> 15
        return Double(h & 0xFFFFFF) / 16777215.0
    }

    // MARK: 云

    private func rebuildClouds(count: Int, pal: Palette, w: Weather) {
        cloudHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard count > 0 else { return }
        let W = bounds.width, H = bounds.height
        let wind = max(1.0, CGFloat(w.windSpeed))
        let scale = max(0.65, W / 1440)

        // 阴天不是「几朵白云」，而是一整片压低的层云：先铺一层大尺度低对比云幕
        if count >= 5 {
            let stratus = CALayer()
            stratus.name = "stratus"
            stratus.bounds = CGRect(x: 0, y: 0, width: W * 1.30, height: H * 0.72)
            stratus.position = CGPoint(x: W * 0.5, y: H * 0.60)
            stratus.backgroundColor = pal.cloud.mixed(.rgb(0.34, 0.40, 0.48), 0.28).cgColor
            stratus.opacity = Float(min(0.40, 0.12 + Double(count) / 12.0 * 0.28))
            let m = CALayer()
            m.frame = stratus.bounds
            m.contents = TextureFactory.fogMasks[1]
            stratus.mask = m
            cloudHost.addSublayer(stratus)

            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = W * 0.44
            drift.toValue = W * 0.56
            drift.duration = 90
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            stratus.add(drift, forKey: "stratusDrift")
        }

        for i in 0..<count {
            let depth = i % 3                       // 0 远 / 1 中 / 2 近
            let sizeMul: CGFloat = [0.72, 1.0, 1.48][depth]
            let speedMul: CGFloat = [0.52, 1.0, 1.85][depth]
            let cw = (240 + CGFloat(Self.rand(i * 61 + 9)) * 300) * scale * sizeMul
            let ch = cw * (0.36 + CGFloat(Self.rand(i * 71 + 4)) * 0.08)
            let y = H * ([0.70, 0.56, 0.40][depth] + CGFloat(Self.rand(i * 83 + 6)) * 0.18)

            let group = CALayer()
            group.bounds = CGRect(x: 0, y: 0, width: cw, height: ch)
            group.position = CGPoint(x: -cw, y: y)
            group.opacity = Float(([0.34, 0.56, 0.74][depth]
                                   + CGFloat(Self.rand(i * 97 + 2)) * 0.10)
                                  * (w.condition == .overcast ? 1.18 : 1))

            let grad = CAGradientLayer()
            grad.frame = group.bounds
            grad.startPoint = CGPoint(x: 0.5, y: 1)
            grad.endPoint = CGPoint(x: 0.5, y: 0)
            grad.locations = [0, 0.45, 1] as [NSNumber]
            grad.colors = cloudColors(pal: pal, st: w.sky(), w: w).map { $0.cgColor }

            let mask = CALayer()
            // 遮罩与云的边界严格重合：纹理四边 alpha 已归零，不会露出矩形框
            mask.frame = group.bounds
            mask.contents = TextureFactory.cloudMasks[(i * 5 + 2) % TextureFactory.cloudMasks.count]
            grad.mask = mask
            group.addSublayer(grad)
            cloudHost.addSublayer(group)

            // 极缓慢地平移噪声内容，云的边缘会「翻卷」，而不是一块剪影在平移
            let fold = CABasicAnimation(keyPath: "contentsRect")
            fold.fromValue = NSValue(rect: CGRect(x: 0, y: 0, width: 0.96, height: 1))
            fold.toValue = NSValue(rect: CGRect(x: 0.04, y: 0, width: 0.96, height: 1))
            fold.duration = CFTimeInterval(38 + Self.rand(i * 109 + 1) * 46)
            fold.autoreverses = true
            fold.repeatCount = .infinity
            fold.timeOffset = fold.duration * CFTimeInterval(Self.rand(i * 107 + 8))
            mask.add(fold, forKey: "fold")

            // 一条带轻微上下起伏的路径，代替「整排匀速直线平移」
            let path = CGMutablePath()
            let bob = 8 + CGFloat(Self.rand(i * 101 + 3)) * 18
            path.move(to: CGPoint(x: -cw, y: y))
            path.addCurve(to: CGPoint(x: W + cw, y: y),
                          control1: CGPoint(x: W * 0.30, y: y + bob),
                          control2: CGPoint(x: W * 0.68, y: y - bob))
            let drift = CAKeyframeAnimation(keyPath: "position")
            drift.path = path
            drift.duration = CFTimeInterval((150 + Self.rand(i * 107 + 8) * 110)
                                            / (1 + Double(wind) / 16) / Double(speedMul))
            drift.repeatCount = .infinity
            drift.calculationMode = .paced
            drift.timeOffset = drift.duration * CFTimeInterval(Self.rand(i * 109 + 1))
            drift.isRemovedOnCompletion = false
            group.add(drift, forKey: "drift")

            // 极缓慢的呼吸，云不是一块剪影在滑动
            let breathe = CABasicAnimation(keyPath: "transform.scale")
            breathe.fromValue = 0.985
            breathe.toValue = 1.025
            breathe.duration = CFTimeInterval(24 + Self.rand(i * 113 + 5) * 26)
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            breathe.timeOffset = breathe.duration * CFTimeInterval(Self.rand(i * 127 + 3))
            group.add(breathe, forKey: "breathe")
        }
    }

    private func cloudColors(pal: Palette, st: SkyState, w: Weather) -> [NSColor] {
        let warm = CGFloat(st.warmth)
        let sunTint: CGFloat = st.isSun ? (0.14 + warm * 0.46) : 0.08
        let lit = pal.cloud.mixed(pal.body, sunTint)
        let darkMix: CGFloat = (w.condition == .heavyRain || w.condition == .thunder) ? 0.46 : 0.38
        let dark = pal.cloud.mixed(.rgb(0.07, 0.09, 0.15), darkMix)
        return [lit, pal.cloud, dark]
    }

    private func retintClouds(pal: Palette, st: SkyState, w: Weather, animated: Bool) {
        let colors = cloudColors(pal: pal, st: st, w: w).map { $0.cgColor }
        CATransaction.begin()
        CATransaction.setAnimationDuration(animated ? 2.2 : 0)
        for group in cloudHost.sublayers ?? [] {
            if group.name == "stratus" {
                group.backgroundColor = pal.cloud.mixed(.rgb(0.34, 0.40, 0.48), 0.28).cgColor
            } else {
                (group.sublayers?.first as? CAGradientLayer)?.colors = colors
            }
        }
        CATransaction.commit()
    }

    // MARK: 雾

    private func rebuildFog(w: Weather) {
        fogHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard w.condition.isFoggy else { return }
        let W = bounds.width, H = bounds.height

        // 全屏雾幕：越靠近地面越浓，压低整幅画面的对比度
        let veil = CAGradientLayer()
        veil.frame = bounds
        veil.startPoint = CGPoint(x: 0.5, y: 0)
        veil.endPoint = CGPoint(x: 0.5, y: 1)
        veil.colors = [NSColor(calibratedWhite: 0.90, alpha: 0.42).cgColor,
                       NSColor(calibratedWhite: 0.90, alpha: 0.20).cgColor,
                       NSColor(calibratedWhite: 0.90, alpha: 0.04).cgColor]
        veil.locations = [0, 0.42, 1] as [NSNumber]
        fogHost.addSublayer(veil)

        for i in 0..<3 {
            let bandH = H * (0.22 + CGFloat(i) * 0.06)
            let g = CALayer()
            g.bounds = CGRect(x: 0, y: 0, width: W * 1.25, height: bandH)
            g.position = CGPoint(x: W * 0.5, y: H * (0.16 + CGFloat(i) * 0.27))
            g.backgroundColor = NSColor(calibratedWhite: 0.94, alpha: 1).cgColor
            g.opacity = Float(0.30 + Double(i) * 0.10)

            let mask = CALayer()
            mask.frame = g.bounds
            mask.contents = TextureFactory.fogMasks[i % TextureFactory.fogMasks.count]
            g.mask = mask
            fogHost.addSublayer(g)

            let drift = CABasicAnimation(keyPath: "position.x")
            drift.fromValue = W * 0.42
            drift.toValue = W * 0.58
            drift.duration = CFTimeInterval(26 + i * 13)
            drift.autoreverses = true
            drift.repeatCount = .infinity
            drift.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            g.add(drift, forKey: "fogDrift")

            let breathe = CABasicAnimation(keyPath: "opacity")
            breathe.fromValue = 0.18 + Double(i) * 0.08
            breathe.toValue = 0.44 + Double(i) * 0.08
            breathe.duration = CFTimeInterval(19 + i * 9)
            breathe.autoreverses = true
            breathe.repeatCount = .infinity
            g.add(breathe, forKey: "fogBreathe")
        }
    }

    // MARK: 雨 / 雪：三层景深

    /// 显式图层 + position 动画，而不是 CAEmitterLayer。
    /// 实测 .line 形状的发射线贴近图层边界时会被系统整体剔除，雨雪根本落不下来。
    private func rebuildParticles(w: Weather) {
        particleHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard w.condition.isRainy || w.condition.isSnowy else { return }
        let k = CGFloat(Settings.shared.intensity)
        let W = bounds.width, H = bounds.height
        let scale = max(0.6, W / 1280)
        let tiltSign: CGFloat = (w.windDirection > 90 && w.windDirection < 270) ? -1 : 1
        let slope = tiltSign * min(0.40, CGFloat(w.windSpeed) / 65 * 0.40)

        if w.condition.isRainy {
            addGroundHaze(color: .rgb(0.82, 0.89, 0.95), alpha: 0.10)
            let base: CGFloat
            switch w.condition {
            case .drizzle: base = 115
            case .heavyRain, .thunder: base = 310
            default: base = 215
            }
            let total = max(30, Int(base * k * scale))
            // 远 / 中 / 近：细短慢淡 → 粗长快实，形成大气透视
            let specs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                // 数量占比, 长度范围, 宽度, 最大不透明度, 基础时长, 时长抖动
                (0.32, 16, 1.2, 0.36, 1.05, 0.35),
                (0.42, 30, 1.9, 0.60, 0.66, 0.28),
                (0.26, 52, 3.0, 0.84, 0.40, 0.20),
            ]
            var idx = 0
            for (d, spec) in specs.enumerated() {
                let count = Int(CGFloat(total) * spec.0)
                let depth = CGFloat(d)
                for j in 0..<count {
                    let i = idx + j
                    let len = (spec.1 * (0.6 + CGFloat(Self.rand(i * 137 + 3)) * 0.8)) *
                              (0.75 + depth * 0.35) * scale
                    let x = CGFloat(Self.rand(i * 139 + 7)) * (W + 260) - 130
                    let l = CALayer()
                    l.contents = TextureFactory.rainStreak
                    l.bounds = CGRect(x: 0, y: 0, width: spec.2 * scale, height: len)
                    l.opacity = Float(spec.3 * (0.65 + CGFloat(Self.rand(i * 149 + 5)) * 0.35))
                    l.position = CGPoint(x: x, y: H + len)
                    l.transform = CATransform3DMakeRotation(
                        -atan(slope) + CGFloat((Self.rand(i * 151 + 9) - 0.5) * 0.05), 0, 0, 1)
                    particleHost.addSublayer(l)

                    let travel = H + len * 2
                    let fall = CABasicAnimation(keyPath: "position")
                    fall.fromValue = NSValue(point: CGPoint(x: x, y: H + len))
                    fall.toValue = NSValue(point: CGPoint(x: x + slope * travel, y: -len))
                    fall.duration = CFTimeInterval(spec.4 * (1 - spec.5 / 2 +
                                    Self.rand(i * 157 + 11) * spec.5))
                    fall.repeatCount = .infinity
                    fall.timeOffset = fall.duration * CFTimeInterval(Self.rand(i * 163 + 13))
                    fall.isRemovedOnCompletion = false
                    l.add(fall, forKey: "fall")
                }
                idx += count
            }
            addSplashes(count: Int(26 * k * scale), W: W, H: H, color: .rgb(0.86, 0.93, 1.0))
        }

        if w.condition.isSnowy {
            addGroundHaze(color: .rgb(0.96, 0.98, 1.0), alpha: 0.16)
            let total = max(32, Int(145 * k * scale))
            let specs: [(CGFloat, CGFloat, CGFloat, CGFloat, CGFloat)] = [
                // 数量占比, 半径, 最大不透明度, 基础时长, 摆幅
                (0.38, 2.4, 0.66, 17, 14),
                (0.38, 4.2, 0.85, 11, 26),
                (0.24, 7.0, 0.98, 7.5, 42),
            ]
            var idx = 0
            for spec in specs {
                let count = Int(CGFloat(total) * spec.0)
                for j in 0..<count {
                    let i = idx + j
                    let r = spec.1 * (0.7 + CGFloat(Self.rand(i * 167 + 3)) * 0.8) * scale
                    let x = CGFloat(Self.rand(i * 173 + 7)) * (W + 200) - 100
                    let sway = spec.4 * (0.5 + CGFloat(Self.rand(i * 179 + 5))) * scale
                    let l = CALayer()
                    l.contents = TextureFactory.snowflake
                    l.bounds = CGRect(x: 0, y: 0, width: r * 3.0, height: r * 3.0)
                    l.opacity = Float(spec.2 * (0.65 + CGFloat(Self.rand(i * 181 + 9)) * 0.35))
                    l.position = CGPoint(x: x, y: H + 40)
                    particleHost.addSublayer(l)

                    // 分段贝塞尔模拟随风飘摆，而不是一条所有人都走的 S 曲线
                    let p = CGMutablePath()
                    let dir: CGFloat = (i % 2 == 0) ? 1 : -1
                    let drift = slope * (H + 120)
                    p.move(to: CGPoint(x: x, y: H + 40))
                    p.addCurve(to: CGPoint(x: x + drift * 0.33, y: H * 0.68),
                               control1: CGPoint(x: x + dir * sway, y: H * 0.92),
                               control2: CGPoint(x: x - dir * sway + drift * 0.2, y: H * 0.80))
                    p.addCurve(to: CGPoint(x: x + drift * 0.66, y: H * 0.34),
                               control1: CGPoint(x: x + dir * sway * 1.4 + drift * 0.4, y: H * 0.54),
                               control2: CGPoint(x: x - dir * sway + drift * 0.55, y: H * 0.44))
                    p.addCurve(to: CGPoint(x: x + drift, y: -40),
                               control1: CGPoint(x: x + dir * sway + drift * 0.75, y: H * 0.22),
                               control2: CGPoint(x: x - dir * sway * 0.6 + drift * 0.9, y: H * 0.10))
                    let fall = CAKeyframeAnimation(keyPath: "position")
                    fall.path = p
                    fall.duration = CFTimeInterval(spec.3 * (0.75 + Self.rand(i * 191 + 11) * 0.6))
                    fall.repeatCount = .infinity
                    fall.calculationMode = .paced
                    fall.timeOffset = fall.duration * CFTimeInterval(Self.rand(i * 193 + 13))
                    fall.isRemovedOnCompletion = false
                    l.add(fall, forKey: "fall")

                    let spin = CABasicAnimation(keyPath: "transform.rotation.z")
                    spin.fromValue = 0
                    spin.toValue = (i % 2 == 0 ? 1 : -1) * Double.pi * 2
                    spin.duration = CFTimeInterval(9 + Self.rand(i * 197 + 3) * 16)
                    spin.repeatCount = .infinity
                    spin.timeOffset = spin.duration * CFTimeInterval(Self.rand(i * 199 + 5))
                    l.add(spin, forKey: "spin")
                }
                idx += count
            }
        }
    }

    private func addGroundHaze(color: NSColor, alpha: CGFloat) {
        let g = CAGradientLayer()
        g.frame = CGRect(x: 0, y: 0, width: bounds.width, height: bounds.height * 0.20)
        g.startPoint = CGPoint(x: 0.5, y: 0)
        g.endPoint = CGPoint(x: 0.5, y: 1)
        g.colors = [color.withAlphaComponent(alpha).cgColor,
                    color.withAlphaComponent(0).cgColor]
        particleHost.addSublayer(g)
    }

    private func addSplashes(count: Int, W: CGFloat, H: CGFloat, color: NSColor) {
        for i in 0..<max(0, count) {
            let x = CGFloat(Self.rand(i * 211 + 7)) * W
            let y = H * 0.02 + CGFloat(Self.rand(i * 223 + 3)) * H * 0.10
            let size: CGFloat = 10 + CGFloat(Self.rand(i * 227 + 5)) * 20
            let s = CALayer()
            s.contents = TextureFactory.splashRing
            s.bounds = CGRect(x: 0, y: 0, width: size, height: size * 0.45)
            s.position = CGPoint(x: x, y: y)
            s.opacity = 0
            particleHost.addSublayer(s)

            let grow = CABasicAnimation(keyPath: "transform.scale")
            grow.fromValue = 0.25
            grow.toValue = 1.9
            grow.duration = 0.72
            grow.repeatCount = .infinity
            grow.timeOffset = grow.duration * CFTimeInterval(Self.rand(i * 229 + 9))
            s.add(grow, forKey: "grow")

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values = [0, 0.48, 0.30, 0]
            fade.keyTimes = [0, 0.12, 0.42, 1]
            fade.duration = 0.72
            fade.repeatCount = .infinity
            fade.timeOffset = fade.duration * CFTimeInterval(Self.rand(i * 229 + 9))
            s.add(fade, forKey: "fade")
        }
    }

    // MARK: 雷电

    private func scheduleLightning(_ on: Bool) {
        lightningWork?.cancel()
        lightningWork = nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flash.opacity = 0
        flash.removeAllAnimations()
        boltHost.opacity = 0
        boltHost.removeAllAnimations()
        boltHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        guard on else { return }

        let work = DispatchWorkItem { [weak self] in
            guard let self, self.weather?.condition.isThunder == true else { return }
            self.strike()
            self.scheduleLightning(true)
        }
        lightningWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 5...14), execute: work)
    }

    private func strike() {
        let W = bounds.width, H = bounds.height
        boltHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        let x = W * (0.18 + CGFloat(Double.random(in: 0...0.64)))
        var seed = UInt32.random(in: 1...UInt32.max)
        let path = Self.boltPath(from: CGPoint(x: x, y: H * 0.82),
                                 to: CGPoint(x: x + CGFloat(Double.random(in: -90...90)), y: H * 0.16),
                                 seed: &seed)

        // 外层电晕 + 内层锐利主干，避免变成一条软绵绵的曲线
        let halo = CAShapeLayer()
        halo.frame = bounds
        halo.path = path
        halo.strokeColor = NSColor(calibratedRed: 0.62, green: 0.80, blue: 1.0, alpha: 0.34).cgColor
        halo.fillColor = nil
        halo.lineWidth = 9
        halo.lineCap = .butt
        halo.lineJoin = .miter
        halo.shadowColor = NSColor(calibratedRed: 0.55, green: 0.75, blue: 1.0, alpha: 1).cgColor
        halo.shadowRadius = 26
        halo.shadowOpacity = 0.9
        boltHost.addSublayer(halo)

        let bolt = CAShapeLayer()
        bolt.frame = bounds
        bolt.path = path
        bolt.strokeColor = NSColor(calibratedRed: 0.94, green: 0.97, blue: 1.0, alpha: 1).cgColor
        bolt.fillColor = nil
        bolt.lineWidth = 2.4
        bolt.lineCap = .butt
        bolt.lineJoin = .miter
        bolt.shadowColor = NSColor.white.cgColor
        bolt.shadowRadius = 8
        bolt.shadowOpacity = 0.9
        boltHost.addSublayer(bolt)

        let flicker = CAKeyframeAnimation(keyPath: "opacity")
        flicker.values = [0, 1, 0.08, 0.82, 0]
        flicker.keyTimes = [0, 0.06, 0.20, 0.32, 1]
        flicker.duration = 0.62
        boltHost.add(flicker, forKey: "bolt")

        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 0.04, 0.52, 0.03, 0.30, 0]
        glow.keyTimes = [0, 0.05, 0.12, 0.26, 0.36, 1]
        glow.duration = 0.72
        flash.add(glow, forKey: "boltGlow")
    }

    private static func boltPath(from: CGPoint, to: CGPoint, seed: inout UInt32) -> CGPath {
        func rnd() -> Double {
            seed = seed &* 1664525 &+ 1013904223
            return Double(seed >> 8) / 16777216.0
        }
        func segment(_ x0: CGFloat, _ y0: CGFloat, _ x1: CGFloat, _ y1: CGFloat,
                     _ steps: Int, _ spread: CGFloat, _ p: CGMutablePath) {
            p.move(to: CGPoint(x: x0, y: y0))
            for s in 1...steps {
                let t = CGFloat(s) / CGFloat(steps)
                let jitter = s == steps ? 0 : CGFloat(rnd() - 0.5) * spread
                p.addLine(to: CGPoint(x: x0 + (x1 - x0) * t + jitter,
                                      y: y0 + (y1 - y0) * t))
            }
        }
        let p = CGMutablePath()
        // 高频小折角：真实闪电是锐利的锯齿折线，不是平滑曲线
        segment(from.x, from.y, to.x, to.y, 21, 26, p)
        for _ in 0..<4 {
            let t = CGFloat(0.18 + rnd() * 0.58)
            let bx = from.x + (to.x - from.x) * t
            let by = from.y + (to.y - from.y) * t
            let dx = CGFloat(rnd() - 0.5) * 170
            segment(bx, by, bx + dx, by - (by - to.y) * (0.25 + rnd() * 0.25), 6, 14, p)
        }
        return p
    }

    // MARK: 天气角标

    private func updateInfo(w: Weather, frame: SkyFrame, st: SkyState, starCount: Int) {
        infoHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard Settings.shared.showInfo, !hidesInfoForPreview else { return }
        let W = bounds.width
        let night = st.stars > 0
        let cw: CGFloat = 258, ch: CGFloat = night ? 130 : 104
        let extra: CGFloat = night ? 26 : 0
        let rect = CGRect(x: W - cw - 28, y: 28, width: cw, height: ch)

        let bg = CAShapeLayer()
        bg.frame = rect
        bg.path = CGPath(roundedRect: CGRect(x: 0, y: 0, width: cw, height: ch),
                         cornerWidth: 14, cornerHeight: 14, transform: nil)
        bg.fillColor = NSColor(calibratedWhite: 0.05, alpha: 0.38).cgColor
        bg.strokeColor = NSColor.white.withAlphaComponent(0.18).cgColor
        bg.lineWidth = 1
        infoHost.addSublayer(bg)

        let scale = NSScreen.main?.backingScaleFactor ?? 2
        func line(_ s: String, _ y: CGFloat, _ font: NSFont, _ alpha: CGFloat) {
            let t = CATextLayer()
            t.contentsScale = scale
            t.frame = CGRect(x: rect.minX + 16, y: rect.minY + y, width: cw - 32, height: 30)
            t.string = NSAttributedString(string: s,
                                          attributes: [.font: font,
                                                       .foregroundColor: NSColor.white.withAlphaComponent(alpha)])
            t.alignmentMode = .left
            t.isWrapped = false
            infoHost.addSublayer(t)
        }

        line("\(w.place.name)   \(Int(w.temperature.rounded()))°", 63 + extra,
             .boldSystemFont(ofSize: 22), 1.0)
        line("\(w.condition.label) · \(st.phase.label) · 体感 \(Int(w.apparent.rounded()))°", 42 + extra,
             .systemFont(ofSize: 12, weight: .medium), 0.88)
        line("风 \(Int(w.windSpeed)) km/h · 湿度 \(w.humidity)% · 云量 \(w.cloudCover)%", 24 + extra,
             .systemFont(ofSize: 11), 0.72)

        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = w.localTimeZone
        let hhmm = { (d: Date) -> String in f.string(from: d) }

        if night {
            let names = frame.visibleConstellations(2).joined(separator: " · ")
            line(names.isEmpty ? "今夜云层较厚，星星被遮住了" : "今夜可见：\(names) 等", 24,
                 .systemFont(ofSize: 10, weight: .medium), 0.78)
            let moon = "月相 \(Int(frame.moonIllumination * 100))%"
            var tail: String
            if sceneLayer.isHidden {
                tail = "真实星图 \(starCount) 颗 · \(moon)"
            } else if Settings.shared.backgroundMode == .eco {
                tail = "当地生态 · \(EcoScene.biome(for: w).label) · \(moon)"
            } else {
                tail = "实景模式 · \(moon)"
            }
            if let mr = Astronomy.dayEvents(date: Date(), place: w.place).moonrise {
                tail += " · 月升 \(hhmm(mr))"
            }
            line(tail + " · 实时", 6,
                 .systemFont(ofSize: 10), 0.58)
        } else {
            // 白天 / 日出 / 日落：直接显示本机算出的当天日出日落，随秒级推进实时刷新
            let ev = Astronomy.dayEvents(date: Date(), place: w.place)
            var s = "日出 \(hhmm(ev.sunrise)) · 日落 \(hhmm(ev.sunset))"
            if let mr = ev.moonrise {
                s += " · 月升 \(hhmm(mr))"
            }
            line(s, 7, .systemFont(ofSize: 10), 0.62)
        }
    }

    deinit {
        lightningWork?.cancel()
        NotificationCenter.default.removeObserver(self)
    }
}

// MARK: - 离屏预览（仅供 tools/preview.swift 使用）

extension SkyView {
    /// 预览用：立即放一道闪电并定格，不等随机计时器
    func previewStrike() {
        strike()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        boltHost.removeAllAnimations()
        flash.removeAllAnimations()
        boltHost.opacity = 1
        flash.opacity = 0.16
        CATransaction.commit()
    }

    /// 把每个动画按它自己的 timeOffset「定格」成 model 值。
    /// 命令行预览工具没有 NSApp.run()，CAAnimation 不会推进；直接读动画参数算一帧，
    /// 就能用静态内容校对云 / 雨 / 雪的分布。会终止该视图的动画，仅限预览用。
    func bakeForStillPreview() {
        guard let root = layer else { return }
        applyFrames()
        func phase(_ a: CAAnimation) -> CGFloat {
            guard a.duration > 0 else { return 0 }
            let t = (a.timeOffset / a.duration).truncatingRemainder(dividingBy: 1)
            return CGFloat(t < 0 ? t + 1 : t)
        }
        func point(_ v: Any?) -> CGPoint? { (v as? NSValue)?.pointValue }
        func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
        func bake(_ l: CALayer) {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            for key in l.animationKeys() ?? [] {
                guard let a = l.animation(forKey: key) else { continue }
                let t = Double(phase(a))
                guard let kp = (a as? CAPropertyAnimation)?.keyPath else { continue }
                switch kp {
                case "position":
                    if let kb = a as? CABasicAnimation,
                       let from = point(kb.fromValue), let to = point(kb.toValue) {
                        l.position = CGPoint(x: from.x + (to.x - from.x) * CGFloat(t),
                                             y: from.y + (to.y - from.y) * CGFloat(t))
                    } else if let kf = a as? CAKeyframeAnimation, let p = kf.path {
                        l.position = Self.sample(path: p, t: CGFloat(t))
                    }
                case "position.x":
                    if let kb = a as? CABasicAnimation,
                       let from = number(kb.fromValue), let to = number(kb.toValue) {
                        l.position.x = CGFloat(from + (to - from) * t)
                    }
                case "opacity":
                    if let kf = a as? CAKeyframeAnimation,
                       let values = kf.values as? [NSNumber], !values.isEmpty {
                        let f = t * Double(values.count - 1)
                        let i = min(values.count - 2, max(0, Int(f)))
                        let u = f - Double(i)
                        l.opacity = Float(values[i].doubleValue +
                                          (values[i + 1].doubleValue - values[i].doubleValue) * u)
                    } else if let kb = a as? CABasicAnimation,
                              let from = number(kb.fromValue), let to = number(kb.toValue) {
                        l.opacity = Float(from + (to - from) * t)
                    }
                default: break
                }
            }
            l.removeAllAnimations()
            CATransaction.commit()
            l.sublayers?.forEach(bake)
            if let m = l.mask { bake(m) }
        }
        bake(root)
    }

    /// 沿 CGPath 的控制点序列近似取一点，够定格预览用
    private static func sample(path: CGPath, t: CGFloat) -> CGPoint {
        var pts: [CGPoint] = []
        path.applyWithBlock { e in
            let el = e.pointee
            switch el.type {
            case .moveToPoint, .addLineToPoint: pts.append(el.points[0])
            case .addQuadCurveToPoint:
                pts.append(el.points[0]); pts.append(el.points[1])
            case .addCurveToPoint:
                pts.append(el.points[0]); pts.append(el.points[1]); pts.append(el.points[2])
            case .closeSubpath: break
            @unknown default: break
            }
        }
        guard pts.count > 1 else { return pts.first ?? .zero }
        let f = min(1, max(0, t)) * CGFloat(pts.count - 1)
        let i = min(pts.count - 2, Int(f))
        let u = f - CGFloat(i)
        return CGPoint(x: pts[i].x + (pts[i + 1].x - pts[i].x) * u,
                       y: pts[i].y + (pts[i + 1].y - pts[i].y) * u)
    }

    /// 离屏兜底：把定格后的 layer 树直接画进位图
    func previewSnapshot(scale s: CGFloat = 1) -> CGImage? {
        guard let root = layer else { return nil }
        bakeForStillPreview()
        let w = Int(bounds.width * s), h = Int(bounds.height * s)
        guard w > 0, h > 0 else { return nil }
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.scaleBy(x: s, y: s)
        root.render(in: ctx)
        return ctx.makeImage()
    }
}
