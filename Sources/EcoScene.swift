import AppKit
import CoreGraphics

// MARK: - 种子化随机 / 颜色
// 同一组经纬度永远得到同一幅画面；换 IP（坐标变了）就得到全新画面。

private struct EcoRNG {
    var s: UInt64
    init(_ seed: UInt64) { s = seed == 0 ? 0x9E3779B97F4A7C15 : seed }
    mutating func next() -> UInt64 {
        s ^= s << 13
        s ^= s >> 7
        s ^= s << 17
        return s
    }
    mutating func unit() -> CGFloat { CGFloat(next() % 1_000_000) / 1_000_000 }
    mutating func range(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * unit() }
}

private func ecoSeed(_ p: Place) -> UInt64 {
    let q = "\(Int(p.latitude * 100))|\(Int(p.longitude * 100))"
    var h: UInt64 = 14695981039346656037
    for b in q.utf8 { h ^= UInt64(b); h &*= 1099511628211 }
    return h
}

private struct EcoRGB {
    var r: CGFloat, g: CGFloat, b: CGFloat
    static func c(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) -> EcoRGB {
        EcoRGB(r: r, g: g, b: b)
    }
    var color: NSColor { NSColor(calibratedRed: r, green: g, blue: b, alpha: 1) }
    func mixed(_ o: EcoRGB, _ t: CGFloat) -> EcoRGB {
        EcoRGB(r: r + (o.r - r) * t, g: g + (o.g - g) * t, b: b + (o.b - b) * t)
    }
    func shaded(_ d: CGFloat) -> EcoRGB {
        EcoRGB(r: min(1, max(0, r + d)), g: min(1, max(0, g + d)), b: min(1, max(0, b + d)))
    }
}

// MARK: - 生态带推断（只用天气数据与经纬度，纯本地，不需要任何外部资源）

enum EcoBiome: String {
    case rainforest, subtropical, temperate, conifer, grassland, steppe,
         desert, tundra, alpine, wetland, coastal, savanna

    var label: String {
        switch self {
        case .rainforest:  return "热带雨林"
        case .subtropical: return "亚热带常绿阔叶林"
        case .temperate:   return "温带落叶林"
        case .conifer:     return "寒温带针叶林"
        case .grassland:   return "温带草原"
        case .steppe:      return "干旱草原"
        case .desert:      return "荒漠"
        case .tundra:      return "苔原雪原"
        case .alpine:      return "高山植被"
        case .wetland:     return "湿地"
        case .coastal:     return "海岸"
        case .savanna:     return "热带稀树草原"
        }
    }

    /// 12 类生态带映射到 8 套内置实景照片包。同类生态共用一套，
    /// 让任何城市换 IP 后都能落到「当地自然生态」的底图，无需逐城配图。
    var photoPack: String {
        switch self {
        case .wetland, .coastal:             return "wetland"
        case .temperate:                     return "temperate"
        case .subtropical:                   return "subtropical"
        case .grassland, .steppe, .savanna:  return "grassland"
        case .desert:                        return "desert"
        case .conifer:                       return "conifer"
        case .tundra, .alpine:               return "tundra"
        case .rainforest:                    return "tropical"
        }
    }

    /// 8 套照片包目录名，自检与打包共用
    static let allPhotoPacks = ["wetland", "temperate", "subtropical", "grassland",
                                "desert", "conifer", "tundra", "tropical"]
}

private func ecoBiome(_ w: Weather) -> EcoBiome {
    let lat = abs(w.place.latitude)
    let t = w.temperature
    let humid = Double(w.humidity)
    let cold = t < -6 || (w.condition == .snow && t < 1)

    if lat > 66 || (cold && lat > 60) { return .tundra }
    if lat > 52 || t < 2 { return .conifer }
    if lat < 23.5 && t > 22 && humid > 70 { return .rainforest }
    if lat < 15 && humid > 62 { return .rainforest }
    if lat < 26 && t > 14 { return .subtropical }
    if t > 27 && humid < 38 { return .desert }
    if lat < 22 && humid < 58 { return .savanna }
    if lat >= 26 && lat < 48 && humid < 42 { return .steppe }
    if humid > 82 && w.precipitation > 0.5 { return .wetland }
    if lat >= 33 && lat < 56 { return .temperate }
    if lat < 30 && humid > 68 { return .subtropical }
    return .grassland
}

/// 按所在半球把月份翻成季节，决定叶色与雪线
private func ecoSeason(_ w: Weather) -> String {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = w.localTimeZone
    let m = cal.component(.month, from: Date())
    let mm = w.place.latitude >= 0 ? m : ((m + 5) % 12) + 1
    switch mm {
    case 12, 1, 2: return "winter"
    case 3, 4, 5:  return "spring"
    case 6, 7, 8:  return "summer"
    default:        return "autumn"
    }
}

private struct EcoPalette {
    var far: EcoRGB, mid: EcoRGB, near: EcoRGB, leaf: EcoRGB, ground: EcoRGB
}

private func ecoPalette(_ b: EcoBiome, _ season: String) -> EcoPalette {
    var far    = EcoRGB.c(0.60, 0.71, 0.78)
    var mid    = EcoRGB.c(0.30, 0.47, 0.46)
    var near   = EcoRGB.c(0.13, 0.30, 0.21)
    var leaf   = EcoRGB.c(0.08, 0.23, 0.13)
    var ground = EcoRGB.c(0.09, 0.20, 0.14)
    switch b {
    case .rainforest:
        mid = .c(0.20, 0.42, 0.34); near = .c(0.07, 0.24, 0.16)
        leaf = .c(0.05, 0.19, 0.11); ground = .c(0.05, 0.16, 0.10)
    case .subtropical:
        mid = .c(0.28, 0.46, 0.43); near = .c(0.11, 0.29, 0.19); leaf = .c(0.07, 0.22, 0.12)
    case .temperate:
        mid = .c(0.34, 0.47, 0.40); near = .c(0.17, 0.31, 0.20); leaf = .c(0.12, 0.27, 0.14)
        if season == "autumn" { leaf = .c(0.52, 0.31, 0.11); near = .c(0.40, 0.32, 0.16) }
        if season == "winter" { leaf = .c(0.20, 0.24, 0.22); near = .c(0.30, 0.34, 0.32) }
    case .conifer:
        mid = .c(0.28, 0.42, 0.45); near = .c(0.10, 0.24, 0.23)
        leaf = .c(0.06, 0.18, 0.16); ground = .c(0.08, 0.17, 0.15)
    case .grassland:
        mid = .c(0.46, 0.55, 0.42); near = .c(0.30, 0.42, 0.20)
        leaf = .c(0.34, 0.42, 0.18); ground = .c(0.28, 0.36, 0.17)
        if season == "autumn" { near = .c(0.48, 0.40, 0.18); leaf = .c(0.56, 0.44, 0.16) }
    case .steppe:
        mid = .c(0.51, 0.54, 0.44); near = .c(0.38, 0.39, 0.24)
        leaf = .c(0.42, 0.40, 0.22); ground = .c(0.36, 0.34, 0.20)
    case .savanna:
        mid = .c(0.48, 0.52, 0.40); near = .c(0.32, 0.39, 0.20)
        leaf = .c(0.26, 0.36, 0.15); ground = .c(0.34, 0.36, 0.18)
    case .desert:
        far = .c(0.78, 0.74, 0.66); mid = .c(0.68, 0.58, 0.42)
        near = .c(0.60, 0.47, 0.30); leaf = .c(0.32, 0.38, 0.22); ground = .c(0.64, 0.51, 0.33)
    case .tundra, .alpine:
        far = .c(0.74, 0.80, 0.85); mid = .c(0.56, 0.64, 0.68)
        near = .c(0.38, 0.46, 0.48); leaf = .c(0.22, 0.30, 0.30); ground = .c(0.62, 0.68, 0.70)
    case .wetland, .coastal:
        mid = .c(0.36, 0.52, 0.55); near = .c(0.16, 0.34, 0.32)
        leaf = .c(0.14, 0.30, 0.22); ground = .c(0.16, 0.30, 0.28)
    }
    return EcoPalette(far: far, mid: mid, near: near, leaf: leaf, ground: ground)
}

// MARK: - 绘制

private final class EcoPainter {
    let ctx: CGContext
    let cs: CGColorSpace
    let W: Int, H: Int
    let biome: EcoBiome
    let season: String
    let pal: EcoPalette
    let st: SkyState
    let weather: Weather
    var rng: EcoRNG

    init(ctx: CGContext, cs: CGColorSpace, W: Int, H: Int,
         w: Weather, st: SkyState, biome: EcoBiome) {
        self.ctx = ctx; self.cs = cs; self.W = W; self.H = H
        self.biome = biome; self.st = st; self.weather = w
        let s = ecoSeason(w)
        self.season = s
        var p = ecoPalette(biome, s)
        // 按实际气温 / 降雪判定积雪，不能只看月份：漠河 11 月初就已零下十几度
        if w.temperature < -3 || w.condition == .snow {
            let snow = EcoRGB.c(0.82, 0.86, 0.88)
            p.far = p.far.mixed(snow, 0.55)
            p.mid = p.mid.mixed(snow, 0.45)
            p.near = p.near.mixed(snow, 0.30)
            p.ground = p.ground.mixed(snow, 0.35)
        }
        self.pal = p
        self.rng = EcoRNG(ecoSeed(w.place))
    }

    func draw() -> CGImage? {
        // 翻转坐标系：让 (0,0) 在左上，y 向下，和屏幕直觉一致
        ctx.translateBy(x: 0, y: CGFloat(H))
        ctx.scaleBy(x: 1, y: -1)
        sky()
        clouds()
        ridges()
        mist()
        water()
        vegetation()
        weatherOverlay()
        vignette()
        return ctx.makeImage()
    }

    private var full: CGRect { CGRect(x: 0, y: 0, width: CGFloat(W), height: CGFloat(H)) }

    private func sky() {
        let p = Palette.make(state: st, condition: weather.condition, cloudCover: weather.cloudCover)
        let colors = [p.top.cgColor, p.mid.cgColor, p.bottom.cgColor] as CFArray
        let loc: [CGFloat] = [0, 0.55, 1]
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: loc) {
            ctx.drawLinearGradient(g, start: .zero,
                                   end: CGPoint(x: 0, y: CGFloat(H) * 0.80),
                                   options: [.drawsAfterEndLocation])
        } else {
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.fill(full)
        }
    }

    private func clouds() {
        // 成团生成，而不是把椭圆均匀撒满天空（那样会变成一条条横纹）
        let groups = weather.condition == .clear ? 7 : 12
        ctx.setFillColor(NSColor.white.cgColor)
        for _ in 0..<groups {
            let gx = rng.range(-80, CGFloat(W) + 80)
            let gy = rng.range(CGFloat(H) * 0.04, CGFloat(H) * 0.44)
            let spread = rng.range(90, 240)
            for _ in 0..<9 {
                let cx = gx + rng.range(-spread, spread)
                let cy = gy + rng.range(-spread * 0.16, spread * 0.16)
                let rx = rng.range(28, 95), ry = rng.range(6, 20)
                ctx.setAlpha(rng.range(0.025, 0.075))
                ctx.fillEllipse(in: CGRect(x: cx - rx, y: cy - ry,
                                           width: rx * 2, height: ry * 2))
            }
        }
        ctx.setAlpha(1)
    }

    /// 多倍频 value noise 生成一条山脊线，形状由坐标种子决定
    private func ridge(_ base: CGFloat, _ amp: CGFloat, _ cell: Int) -> [CGFloat] {
        var out = [CGFloat](repeating: base * CGFloat(H), count: W)
        var a = amp, c = cell
        for _ in 0..<5 {
            let k = max(3, W / max(8, c) + 3)
            var pts = [CGFloat](); pts.reserveCapacity(k)
            for _ in 0..<k { pts.append(rng.unit() - 0.5) }
            for x in 0..<W {
                let xi = CGFloat(x) / CGFloat(max(1, W - 1)) * CGFloat(k - 2)
                let i = min(k - 2, Int(xi))
                var f = xi - CGFloat(i)
                f = f * f * (3 - 2 * f)
                out[x] += a * (pts[i] * (1 - f) + pts[i + 1] * f)
            }
            a *= 0.5
            c = max(8, c / 2)
        }
        return out
    }

    private func fillRidge(_ ys: [CGFloat], _ top: EcoRGB, _ bottom: EcoRGB) {
        ctx.saveGState()
        let p = CGMutablePath()
        p.move(to: CGPoint(x: 0, y: CGFloat(H)))
        for x in 0..<W { p.addLine(to: CGPoint(x: CGFloat(x), y: ys[x])) }
        p.addLine(to: CGPoint(x: CGFloat(W), y: CGFloat(H)))
        p.closeSubpath()
        ctx.addPath(p)
        ctx.clip()
        let colors = [top.color.cgColor, bottom.color.cgColor] as CFArray
        let loc: [CGFloat] = [0, 1]
        if let g = CGGradient(colorsSpace: cs, colors: colors, locations: loc) {
            ctx.drawLinearGradient(g, start: .zero,
                                   end: CGPoint(x: 0, y: CGFloat(H)), options: [])
        } else {
            ctx.setFillColor(top.color.cgColor)
            ctx.fill(full)
        }
        ctx.restoreGState()
    }

    private func ridges() {
        let y1 = ridge(0.545, 42, 260)
        let y2 = ridge(0.605, 68, 210)
        let y3 = ridge(0.680, 92, 175)
        let y4 = ridge(0.775, 120, 140)
        fillRidge(y1, pal.far, pal.far.mixed(pal.mid, 0.35))
        fillRidge(y2, pal.far.mixed(pal.mid, 0.55), pal.mid)
        fillRidge(y3, pal.mid.mixed(pal.near, 0.55), pal.near)
        fillRidge(y4, pal.near.mixed(pal.ground, 0.35), pal.ground)
    }

    private func mist() {
        ctx.setFillColor(NSColor.white.cgColor)
        for _ in 0..<24 {
            let cy = rng.range(CGFloat(H) * 0.56, CGFloat(H) * 0.75)
            let rx = rng.range(110, 400), ry = rng.range(6, 20)
            ctx.setAlpha(rng.range(0.02, 0.07))
            ctx.fillEllipse(in: CGRect(x: rng.range(-120, CGFloat(W)), y: cy - ry,
                                       width: rx * 2, height: ry * 2))
        }
        ctx.setAlpha(1)
    }

    private func water() {
        switch biome {
        case .coastal, .wetland, .rainforest: break
        default: return
        }
        let top = CGFloat(H) * 0.86
        let c = pal.near.mixed(EcoRGB.c(0.44, 0.60, 0.70), 0.55)
        ctx.setFillColor(c.color.cgColor)
        ctx.fill(CGRect(x: 0, y: top, width: CGFloat(W), height: CGFloat(H) - top))
        ctx.setFillColor(NSColor.white.cgColor)
        for _ in 0..<46 {
            ctx.setAlpha(rng.range(0.04, 0.15))
            ctx.fill(CGRect(x: rng.range(0, CGFloat(W)), y: rng.range(top, CGFloat(H) - 4),
                            width: rng.range(28, 190), height: rng.range(0.6, 1.8)))
        }
        ctx.setAlpha(1)
    }

    private func vegetation() {
        let snowy = weather.condition == .snow || biome == .tundra || biome == .alpine
            || (season == "winter" && weather.temperature < 3)
        let count: Int
        switch biome {
        case .desert: count = 28
        case .tundra, .alpine, .grassland, .steppe, .savanna: count = 52
        default: count = 96
        }
        for _ in 0..<count {
            let x = rng.range(-40, CGFloat(W) + 40)
            let y = rng.range(CGFloat(H) * 0.79, CGFloat(H) * 1.04)
            let s = rng.range(22, 84) * (0.72 + max(0, y / CGFloat(H) - 0.8) * 2.0)
            drawPlant(x, y, s, pal.leaf.shaded(rng.range(-0.03, 0.05)), snowy: snowy)
        }
    }

    private func drawPlant(_ x: CGFloat, _ y: CGFloat, _ s: CGFloat, _ c: EcoRGB, snowy: Bool) {
        ctx.setFillColor(c.color.cgColor)
        switch biome {
        case .conifer, .tundra, .alpine:
            for k in 0..<3 {
                let ty = y - s * 1.55 + CGFloat(k) * s * 0.46
                let w = s * 0.44 * (1 - CGFloat(k) * 0.18)
                let p = CGMutablePath()
                p.move(to: CGPoint(x: x, y: ty))
                p.addLine(to: CGPoint(x: x - w, y: ty + s * 0.85))
                p.addLine(to: CGPoint(x: x + w, y: ty + s * 0.85))
                p.closeSubpath()
                ctx.addPath(p); ctx.fillPath()
            }
        case .desert:
            ctx.fill(CGRect(x: x - s * 0.10, y: y - s * 1.5, width: s * 0.20, height: s * 1.6))
            ctx.fill(CGRect(x: x - s * 0.44, y: y - s * 1.05, width: s * 0.36, height: s * 0.13))
            ctx.fill(CGRect(x: x - s * 0.44, y: y - s * 1.42, width: s * 0.13, height: s * 0.42))
            ctx.fill(CGRect(x: x + s * 0.08, y: y - s * 0.92, width: s * 0.34, height: s * 0.13))
            ctx.fill(CGRect(x: x + s * 0.29, y: y - s * 1.26, width: s * 0.13, height: s * 0.38))
        case .grassland, .steppe, .savanna:
            for k in 0..<6 {
                let bx = x + CGFloat(k - 3) * s * 0.13
                let p = CGMutablePath()
                p.move(to: CGPoint(x: bx, y: y))
                p.addLine(to: CGPoint(x: bx + rng.range(-s * 0.34, s * 0.34),
                                      y: y - s * rng.range(0.55, 1.15)))
                p.addLine(to: CGPoint(x: bx + s * 0.07, y: y))
                p.closeSubpath()
                ctx.addPath(p); ctx.fillPath()
            }
        default:
            for _ in 0..<4 {
                let ox = rng.range(-0.5, 0.5) * s
                let oy = rng.range(-0.42, 0.3) * s
                ctx.fillEllipse(in: CGRect(x: x + ox - s * 0.46, y: y + oy - s * 0.34,
                                           width: s * 0.92, height: s * 0.68))
            }
        }
        if snowy {
            ctx.setFillColor(NSColor.white.withAlphaComponent(0.72).cgColor)
            ctx.fillEllipse(in: CGRect(x: x - s * 0.34, y: y - s * 0.62,
                                       width: s * 0.68, height: s * 0.20))
        }
    }

    private func weatherOverlay() {
        if st.phase == .night {
            ctx.setFillColor(NSColor(calibratedRed: 0.02, green: 0.05, blue: 0.15, alpha: 0.52).cgColor)
            ctx.fill(full)
        }
        switch weather.condition {
        case .rain, .heavyRain, .thunder, .drizzle, .fog:
            ctx.setFillColor(NSColor(calibratedRed: 0.28, green: 0.34, blue: 0.40, alpha: 0.20).cgColor)
            ctx.fill(full)
        case .snow, .sleet:
            ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.09).cgColor)
            ctx.fill(full)
        default: break
        }
    }

    private func vignette() {
        let colors = [NSColor.black.withAlphaComponent(0).cgColor,
                      NSColor.black.withAlphaComponent(0.24).cgColor] as CFArray
        let loc: [CGFloat] = [0.55, 1]
        guard let g = CGGradient(colorsSpace: cs, colors: colors, locations: loc) else { return }
        let center = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) * 0.45)
        ctx.drawRadialGradient(g, startCenter: center, startRadius: 0,
                               endCenter: center, endRadius: CGFloat(W) * 0.75,
                               options: [.drawsAfterEndLocation])
    }
}

// MARK: - 对外接口

enum EcoScene {
    /// key 里带坐标：换 IP 后自然生成新图，无需手动失效；限制条数避免长时间运行占内存
    private static var cache: [String: CGImage] = [:]
    private static let cacheLimit = 24

    static func invalidate() { cache.removeAll() }

    static func biome(for w: Weather) -> EcoBiome { ecoBiome(w) }

    static func image(for w: Weather, st: SkyState, size: CGSize) -> CGImage? {
        let W = max(320, Int(size.width.rounded()))
        let H = max(200, Int(size.height.rounded()))
        let b = ecoBiome(w)
        let s = ecoSeason(w)
        let key = "\(Int(w.place.latitude * 100))|\(Int(w.place.longitude * 100))|"
            + "\(b.rawValue)|\(s)|\(String(describing: st.phase))|"
            + "\(w.condition.rawValue)|\(W)x\(H)"
        if let hit = cache[key] { return hit }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: W, height: H,
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let painter = EcoPainter(ctx: ctx, cs: cs, W: W, H: H, w: w, st: st, biome: b)
        guard let img = painter.draw() else { return nil }
        if cache.count >= cacheLimit { cache.removeAll() }
        cache[key] = img
        return img
    }
}
