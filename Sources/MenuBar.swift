import AppKit
import ServiceManagement

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ on: Bool) throws {
        if on { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }
}

final class MenuBarController: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private var lastWeather: Weather?
    private var lastError: Error?

    func start() {
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        item.button?.imagePosition = .imageLeading
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        show(weather: nil, error: nil)
        HotKeys.install { [weak self] id in
            switch id {
            case 1: self?.popupMenuAtMouse()
            case 2: self?.toggleEnabled()
            case 3: self?.refreshNow()
            default: break
            }
        }
    }

    /// 状态项被菜单栏管理器折叠时，⌃⌥W 直接在鼠标位置弹出同一份菜单
    func popupMenuAtMouse() {
        NSApp.activate(ignoringOtherApps: true)
        item.menu?.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    func update(_ result: Result<Weather, Error>) {
        switch result {
        case .success(let w): show(weather: w, error: nil)
        case .failure(let e): show(weather: lastWeather, error: e)
        }
    }

    private func show(weather w: Weather?, error: Error?) {
        lastWeather = w ?? lastWeather
        lastError = error
        let cond = w?.condition ?? .partlyCloudy
        let phase = (w.map { Astronomy.skyState(place: $0.place).phase }) ?? .day
        let symbol = cond == .clear && phase == .night ? "moon.stars.fill" : cond.symbol
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: cond.label)
            ?? NSImage(systemSymbolName: "cloud.sun.fill", accessibilityDescription: nil)
        img?.isTemplate = true
        item.button?.image = img
        if let w {
            item.button?.title = " \(Int(w.temperature.rounded()))°"
            let ev = Astronomy.dayEvents(place: w.place)
            let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = w.localTimeZone
            item.button?.toolTip =
                "\(w.place.display) · \(cond.label) · \(phase.label)\n" +
                "\(Int(w.temperature.rounded()))°C · 体感 \(Int(w.apparent.rounded()))° · 风 \(Int(w.windSpeed)) km/h\n" +
                "日出 \(f.string(from: ev.sunrise)) · 日落 \(f.string(from: ev.sunset))\n" +
                "当地 \(w.timeZoneName) · 观测于 \(w.observedTimeString)"
        } else {
            item.button?.title = " 天气"
            item.button?.toolTip = error?.localizedDescription ?? "正在获取当地天气…"
        }
    }

    // MARK: 菜单

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        if let w = lastWeather {
            let phase = Astronomy.skyState(place: w.place).phase
            disabled("\(w.place.display)  ·  \(w.condition.label)  ·  \(phase.label)", menu)
            disabled("\(Int(w.temperature.rounded()))°C   体感 \(Int(w.apparent.rounded()))°   " +
                     "风 \(Int(w.windSpeed)) km/h   湿度 \(w.humidity)%   降水 \(String(format: "%.1f", w.precipitation)) mm", menu)
            let ev = Astronomy.dayEvents(place: w.place)
            let f = DateFormatter(); f.dateFormat = "HH:mm"; f.timeZone = w.localTimeZone
            let hhmm = { (d: Date) -> String in f.string(from: d) }
            disabled("日出 \(hhmm(ev.sunrise))  ·  日落 \(hhmm(ev.sunset))", menu)
            let next = nextSolarEvent(ev, from: Date())
            disabled("下一次\(next.kind) \(hhmm(next.date))（\(countdown(next.date.timeIntervalSince(Date()))))", menu)
            if phase == .night {
                let names = Astronomy.frame(place: w.place).visibleConstellations(3)
                if !names.isEmpty {
                    disabled("今夜可见：\(names.joined(separator: " · "))", menu)
                }
            }
        } else {
            disabled("正在获取当地天气…", menu)
        }
        if let e = lastError { disabled("⚠︎ \(e.localizedDescription)", menu) }
        menu.addItem(.separator())

        add("立即刷新            ⌃⌥R", #selector(refreshNow), menu)
        add("显示桌面天气      ⌃⌥D", #selector(toggleEnabled), menu, on: s.enabled)
        add("显示天气角标", #selector(toggleInfo), menu, on: s.showInfo)
        add("显示星座连线与星名", #selector(toggleStarLabels), menu, on: s.showConstellations)
        let bg = NSMenu()
        add("实景照片 + 粒子效果", #selector(setBackgroundMode(_:)), bg,
            on: s.backgroundMode == .photo, tag: BackgroundMode.photo.rawValue)
        add("程序化天空（无底图）", #selector(setBackgroundMode(_:)), bg,
            on: s.backgroundMode == .sky, tag: BackgroundMode.sky.rawValue)
        add("当地生态绘制（实验）", #selector(setBackgroundMode(_:)), bg,
            on: s.backgroundMode == .eco, tag: BackgroundMode.eco.rawValue)
        bg.addItem(.separator())
        add("每 2 小时更换底图", #selector(toggleTwoHourScenes), bg, on: s.twoHourScenes)
        bg.addItem(.separator())
        add("实时光线（太阳 / 天气驱动）", #selector(toggleRealtimeLighting), bg, on: s.realtimeLighting)
        if s.twoHourScenes {
            let tz = lastWeather.map { SceneClock.timeZone($0) } ?? .current
            let slot = SceneClock.slot(timeZone: tz)
            disabled("当前档位  \(SceneClock.label(slot))", bg)
            let kind: String
            if let w = lastWeather {
                if w.condition.isRainy || w.condition.isSnowy || w.condition.isFoggy {
                    kind = "雨雪 / 雾天版"
                } else {
                    kind = w.isSunnyScene ? "晴天通透版" : "阴天柔和版"
                }
            } else {
                kind = "待定位"
            }
            disabled("当前底图  \(kind)", bg)
        }
        add("按生态带自动切换背景", #selector(toggleAutoBiome), bg, on: s.autoBiome)
        submenu("背景来源", bg, menu)

        // 公开实时摄像头：默认关闭，开启后用附近摄像头的最新一帧替换静态底图
        let live = NSMenu()
        add("启用公开实时摄像头", #selector(toggleLiveCam), live, on: s.liveCamEnabled)
        live.addItem(.separator())
        disabled(LiveCamFeed.shared.status, live)
        if let u = LiveCamFeed.shared.lastUpdated {
            let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
            disabled("最近一帧  \(df.string(from: u))", live)
        }
        live.addItem(.separator())
        let camPlace = lastWeather?.place ?? s.lastPlace ?? Place.fallback
        add("自动选最近（\(camPlace.display)）", #selector(pinLiveCam(_:)), live,
            on: s.liveCamID == nil, tag: "")
        for c in LiveCamCatalog.candidates(for: camPlace, limit: 8) {
            let km = Int(LiveCamCatalog.km(camPlace.latitude, camPlace.longitude,
                                           c.latitude, c.longitude))
            add("\(c.display)  ·  \(km) km", #selector(pinLiveCam(_:)), live,
                on: s.liveCamID == c.id, tag: c.id)
        }
        live.addItem(.separator())
        let intv = NSMenu()
        for sec in [15, 20, 30, 60, 120] {
            add(sec < 60 ? "每 \(sec) 秒" : "每 \(sec / 60) 分钟",
                #selector(setLiveInterval(_:)), intv,
                on: s.liveCamInterval == sec, tag: Double(sec))
        }
        submenu("抓帧间隔", intv, live)
        add("立即抓一帧", #selector(refreshLiveCam), live)
        live.addItem(.separator())
        disabled("画面来自公开摄像头，可能带站点水印 / 时间戳", live)
        disabled("取不到画面时自动回退到静态背景", live)
        submenu("实时摄像头", live, menu)
        menu.addItem(.separator())

        let intensity = NSMenu()
        for (title, v) in [("轻", 0.5), ("适中", 1.0), ("浓", 1.5)] as [(String, Double)] {
            add(title, #selector(setIntensity(_:)), intensity, on: abs(s.intensity - v) < 0.01, tag: v)
        }
        submenu("雨雪强度", intensity, menu)

        let opacity = NSMenu()
        for (title, v) in [("30% 透出原壁纸", 0.30), ("60%", 0.60), ("85%", 0.85), ("100% 纯天空", 1.0)]
            as [(String, Double)] {
            add(title, #selector(setOpacity(_:)), opacity, on: abs(s.skyOpacity - v) < 0.01, tag: v)
        }
        submenu("背景浓度", opacity, menu)

        let freq = NSMenu()
        for m in [5, 10, 30] {
            add("每 \(m) 分钟", #selector(setFrequency(_:)), freq, on: s.refreshMinutes == m, tag: Double(m))
        }
        submenu("同步频率", freq, menu)
        menu.addItem(.separator())

        let loc = NSMenu()
        for mode in [LocationMode.autoIP, .precise] {
            add(mode.label, #selector(setLocMode(_:)), loc, on: s.locationMode == mode, tag: mode.rawValue)
        }
        add("手动指定城市…", #selector(chooseCity), loc, on: s.locationMode == .manual)
        if let p = s.manualPlace { disabled("当前：\(p.display)", loc) }
        submenu("定位方式", loc, menu)

        let demo = NSMenu()
        add("关闭演示（实时天气）", #selector(setDemo(_:)), demo,
            on: WeatherService.shared.demo == nil, tag: "")
        demo.addItem(.separator())
        for d in Demo.allCases {
            add(d.label, #selector(setDemo(_:)), demo,
                on: WeatherService.shared.demo == d, tag: d.rawValue)
        }
        submenu("预览效果", demo, menu)
        menu.addItem(.separator())

        add("开机启动", #selector(toggleLogin), menu, on: LoginItem.isEnabled)
        add("关于天气桌面", #selector(about), menu)
        add("退出", #selector(quit), menu, key: "q")
    }

    private func disabled(_ title: String, _ menu: NSMenu) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.isEnabled = false
        menu.addItem(mi)
    }

    private func add(_ title: String, _ action: Selector, _ menu: NSMenu,
                     key: String = "", on: Bool = false, tag: Any? = nil) {
        let mi = NSMenuItem(title: title, action: action, keyEquivalent: key)
        mi.target = self
        mi.state = on ? .on : .off
        mi.representedObject = tag
        menu.addItem(mi)
    }

    private func submenu(_ title: String, _ sub: NSMenu, _ menu: NSMenu) {
        let mi = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        mi.submenu = sub
        menu.addItem(mi)
    }

    /// 距 now 最近的下一个太阳事件（日出或日落）
    private func nextSolarEvent(_ ev: SkyEvents, from now: Date) -> (kind: String, date: Date) {
        let cands: [(String, Date)] = [("日出", ev.nextSunrise), ("日落", ev.nextSunset)]
        let future = cands.filter { $0.1 > now }.sorted { $0.1 < $1.1 }
        return future.first ?? ("日出", ev.nextSunrise)
    }

    private func countdown(_ i: TimeInterval) -> String {
        let s = max(0, Int(i))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return "\(h) 小时 \(m) 分" }
        if m > 0 { return "\(m) 分" }
        return "\(s) 秒"
    }

    // MARK: 动作

    @objc private func refreshNow() {
        item.button?.title = " 同步中"
        WeatherService.shared.refresh()
    }

    @objc private func toggleEnabled() {
        Settings.shared.enabled = !Settings.shared.enabled
    }

    @objc private func toggleInfo() {
        Settings.shared.showInfo = !Settings.shared.showInfo
    }

    @objc private func toggleStarLabels() {
        Settings.shared.showConstellations = !Settings.shared.showConstellations
    }

    @objc private func setBackgroundMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let m = BackgroundMode(rawValue: raw) else { return }
        // 先清底图缓存，再写偏好（同步触发 rebuild），最后补一帧确保动画层重建
        SkyView.invalidateScenes()
        Settings.shared.backgroundMode = m
        DesktopController.shared.reapply()
    }

    @objc private func toggleTwoHourScenes() {
        SkyView.invalidateScenes()
        Settings.shared.twoHourScenes = !Settings.shared.twoHourScenes
        DesktopController.shared.reapply()
    }

    @objc private func toggleAutoBiome() {
        SkyView.invalidateScenes()
        Settings.shared.autoBiome = !Settings.shared.autoBiome
        DesktopController.shared.reapply()
    }

    @objc private func toggleRealtimeLighting() {
        SkyView.invalidateScenes()
        Settings.shared.realtimeLighting = !Settings.shared.realtimeLighting
        DesktopController.shared.reapply()
    }

    @objc private func toggleLiveCam() {
        let on = !Settings.shared.liveCamEnabled
        Settings.shared.liveCamEnabled = on
        LiveCamFeed.shared.setEnabled(on)
        DesktopController.shared.reapply()
    }

    @objc private func pinLiveCam(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        let id: String? = raw.isEmpty ? nil : raw
        Settings.shared.liveCamID = id
        LiveCamFeed.shared.pin(id)
        DesktopController.shared.reapply()
    }

    @objc private func setLiveInterval(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.liveCamInterval = Int(v)
        LiveCamFeed.shared.setInterval(Int(v))
    }

    @objc private func refreshLiveCam() {
        LiveCamFeed.shared.refreshNow()
    }

    @objc private func setIntensity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.intensity = v
    }

    @objc private func setOpacity(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.skyOpacity = v
    }

    @objc private func setFrequency(_ sender: NSMenuItem) {
        guard let v = sender.representedObject as? Double else { return }
        Settings.shared.refreshMinutes = Int(v)
        WeatherService.shared.refresh()
    }

    @objc private func setLocMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = LocationMode(rawValue: raw) else { return }
        Settings.shared.locationMode = mode
        WeatherService.shared.demo = nil
        WeatherService.shared.refresh()
    }

    @objc private func setDemo(_ sender: NSMenuItem) {
        let raw = sender.representedObject as? String ?? ""
        WeatherService.shared.demo = raw.isEmpty ? nil : Demo(rawValue: raw)
        WeatherService.shared.refresh()
    }

    @objc private func chooseCity() {
        let alert = NSAlert()
        alert.messageText = "手动指定城市"
        alert.informativeText = "输入城市名（中文或英文），例如：上海 / Beijing / Tokyo"
        alert.addButton(withTitle: "搜索并切换")
        alert.addButton(withTitle: "取消")
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.placeholderString = "城市名"
        field.bezelStyle = .roundedBezel
        alert.accessoryView = field
        NSApp.activate(ignoringOtherApps: true)
        alert.window.level = .floating
        guard alert.runModal() == .alertFirstButtonReturn,
              !field.stringValue.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let q = field.stringValue.trimmingCharacters(in: .whitespaces)
        WeatherService.shared.searchCity(q) { places in
            guard let p = places.first else {
                let a = NSAlert()
                a.messageText = "没找到「\(q)」"
                a.informativeText = "换个写法试试，例如 Shanghai、Beijing、Tokyo。"
                a.runModal()
                return
            }
            Settings.shared.manualPlace = p
            Settings.shared.locationMode = .manual
            WeatherService.shared.demo = nil
            WeatherService.shared.refresh()
        }
    }

    @objc private func toggleLogin() {
        do {
            try LoginItem.set(!LoginItem.isEnabled)
            Settings.shared.launchAtLogin = LoginItem.isEnabled
        } catch {
            let a = NSAlert()
            a.messageText = "无法设置开机启动"
            a.informativeText = error.localizedDescription
            a.runModal()
        }
    }

    @objc private func about() {
        let a = NSAlert()
        a.messageText = "天气桌面 for Mac"
        a.informativeText =
            "把当地实时天气画到桌面上：下雨就有雨、下雪就飘雪、日落就是晚霞。\n\n" +
            "· 天气数据：Open-Meteo（免费、无需 API Key）\n" +
            "· 实时摄像头（可选）：opencam.live 公开摄像头实时帧，取不到自动回退静态背景\n" +
            "· 定位：IP 自动定位 / 系统精确定位 / 手动城市\n" +
            "· 太阳 / 月亮 / 日出日落 / 月升月落由本机实时推算，天气每 5~30 分钟同步\n" +
            "· 纯 Swift + AppKit，不联网上传任何数据\n\n" +
            "快捷键：⌃⌥W 在鼠标处呼出菜单 · ⌃⌥D 显示/隐藏 · ⌃⌥R 立即刷新\n" +
            "菜单栏「预览效果」可以直接查看各种天气的桌面。"
        a.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        a.window.level = .floating
        a.runModal()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
