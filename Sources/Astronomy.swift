import Foundation
import CoreGraphics

// MARK: - 球面坐标

/// 地平坐标：alt 为高度角，az 从正北起算向东，均为弧度
struct Horizontal {
    let alt: Double
    let az: Double
    var altDeg: Double { alt * 180 / .pi }
}

struct PlanetPosition {
    let name: String
    let position: Horizontal
    let mag: Double
    let color: (Double, Double, Double)
}

/// 一颗恒星在观测时刻的状态（已做岁差与大气折射）
struct StarPosition {
    let index: Int
    let position: Horizontal
    let extinctedMag: Double
}

struct ProjectedStar {
    let index: Int
    let point: CGPoint       // 归一化，y 从屏幕底部起算
    let mag: Double          // 消光后的视星等
    let bv: Double
    let altDeg: Double
}

// MARK: - 观测时刻的天球

/// 某一时刻、某一地点的整片天空。所有天体（含太阳月亮行星）共用同一套投影，
/// 所以「星星在月亮旁边」是真的在同一方向，而不是各自摆出来的装饰。
struct SkyFrame {
    let date: Date
    let jd: Double
    let lst: Double                 // 本地平恒星时，弧度
    let latDeg: Double
    let lonDeg: Double
    let centerAz: Double            // 相机朝向（弧度，0=北）
    let centerAlt: Double
    let halfScale: Double           // 立体投影的半视场尺度
    let sun: Horizontal
    let moon: Horizontal
    let moonPhase: Double           // 0 朔 / 0.5 望 / 1 朔
    let moonIllumination: Double
    let planets: [PlanetPosition]
    let stars: [StarPosition]       // 地平线以上的恒星
    let constellationCounts: [(String, Int)]
    let limitMag: Double
    let darkness: Double            // 0 白昼 … 1 天文夜

    /// 把地平坐标投到屏幕上（保角的立体投影，星座形状不畸变）。
    /// 返回 nil 表示在相机背后；坐标 y 从底部起算，超出 0…1 即在画面外。
    func project(_ h: Horizontal, size: CGSize) -> CGPoint? {
        let A = centerAz
        let sa = sin(A), ca = cos(A), s0 = sin(centerAlt), c0 = cos(centerAlt)
        let salt = sin(h.alt), calt = cos(h.alt)

        // 相机前向 f、右向 r、上向 u（在东/北/天顶基下），与方向向量 v 点乘
        let e = calt * sin(h.az), n = calt * cos(h.az), up = salt
        let fE = c0 * sa, fN = c0 * ca, fU = s0
        let rE = ca, rN = -sa, rU = 0.0
        let uE = -sa * s0, uN = -ca * s0, uU = c0

        let Z = e * fE + n * fN + up * fU
        guard Z > 0.02 else { return nil }
        let X = e * rE + n * rN + up * rU
        let Y = e * uE + n * uN + up * uU
        let k = 2 / (1 + Z)
        let aspect = Double(size.width) / max(1, Double(size.height))
        let nx = X * k / halfScale
        let ny = Y * k / halfScale * aspect
        return CGPoint(x: 0.5 + nx * 0.5, y: 0.5 + ny * 0.5)
    }

    /// 屏幕内、亮于极限星等的恒星
    func projectedStars(size: CGSize) -> [ProjectedStar] {
        var out: [ProjectedStar] = []
        out.reserveCapacity(1800)
        for s in stars {
            guard s.extinctedMag <= limitMag,
                  let p = project(s.position, size: size),
                  p.x > -0.02, p.x < 1.02, p.y > -0.02, p.y < 1.02 else { continue }
            let star = StarCatalog.stars[s.index]
            out.append(ProjectedStar(index: s.index, point: p,
                                     mag: s.extinctedMag, bv: star.bv,
                                     altDeg: s.position.altDeg))
        }
        return out
    }

    func visibleConstellations(_ n: Int = 3) -> [String] {
        constellationCounts.prefix(n).map { $0.0 }
    }
}

// MARK: - 天文计算

enum Astronomy {
    private static let j2000: Double = 2451545.0
    private static let deg = Double.pi / 180
    private static var cachedKey = ""
    private static var cachedFrame: SkyFrame?

    /// 同一时刻 / 同一地点 / 同一尺寸无关的数据只算一次，多块屏幕共用。
    /// 20 秒一档：恒星每分钟只走 0.25°，这个粒度肉眼无法分辨。
    static func frame(date: Date = Date(), place: Place) -> SkyFrame {
        let slot = Int(date.timeIntervalSince1970 / 20)
        let key = "\(slot)|\(Int(place.latitude * 1000))|\(Int(place.longitude * 1000))"
        if key == cachedKey, let f = cachedFrame { return f }
        let f = build(date: date, place: place)
        cachedKey = key
        cachedFrame = f
        return f
    }

    private static func build(date: Date, place: Place) -> SkyFrame {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let T = (jd - j2000) / 36525
        let lst = localSiderealTime(jd: jd, T: T, lonDeg: place.longitude)
        let lat = place.latitude * deg

        // 相机：北半球朝南、南半球朝北（能看到最丰富的季节星座）
        let centerAz = (place.latitude >= 0 ? 180.0 : 0.0) * deg
        let centerAlt = 31.0 * deg
        let halfScale = 2 * tan(35.5 * deg)    // 水平视场 142°（立体投影：2·tan(半视场/2)）

        let (sunLon, _) = sunEcliptic(T: T)
        let sunEq = eclipticToEquatorial(lon: sunLon, lat: 0, T: T)
        let sun = toHorizontal(ra: sunEq.ra, dec: sunEq.dec, lst: lst, lat: lat)

        let moonEq = moonEquatorial(T: T, jd: jd)
        let moon = toHorizontal(ra: moonEq.ra, dec: moonEq.dec, lst: lst, lat: lat)
        var phase = (moonEq.lon - sunLon) / (2 * .pi)
        phase -= floor(phase)
        let illum = (1 - cos(2 * .pi * phase)) / 2

        let sunDeg = sun.altDeg
        // 民用 / 航海 / 天文暮光：-0.8° 到 -18° 连续淡入
        let darkness = clamp((-sunDeg - 0.8) / 16, 0, 1)
        let moonUp = moon.altDeg > 0
        let moonGlare = moonUp ? pow(illum, 1.4) * 2.4 * clamp(moon.altDeg / 35, 0, 1) : 0
        let limitMag = 6.5 - (1 - darkness) * 8.7 - moonGlare - 0.55 * darkness

        // 岁差矩阵：把 J2000 的依巴谷坐标转到观测历元
        let T2 = T * T, T3 = T2 * T
        let zeta = (2306.2181 * T + 0.30188 * T2 + 0.017998 * T3) / 3600 * deg
        let z = (2306.2181 * T + 1.09468 * T2 + 0.018203 * T3) / 3600 * deg
        let theta = (2004.3109 * T - 0.42665 * T2 - 0.041833 * T3) / 3600 * deg
        let cz = cos(theta), sz = sin(theta)

        let catalog = StarCatalog.stars
        var positions: [StarPosition] = []
        positions.reserveCapacity(4600)
        var conCount: [UInt8: Int] = [:]

        for i in catalog.indices {
            let s = catalog[i]
            let ra0 = s.ra + zeta
            let sd0 = sin(s.dec), cd0 = cos(s.dec)
            let A = cd0 * sin(ra0)
            let B = cz * cd0 * cos(ra0) - sz * sd0
            let C = sz * cd0 * cos(ra0) + cz * sd0
            let ra = atan2(A, B) + z
            let dec = asin(max(-1, min(1, C)))
            let h = toHorizontal(ra: ra, dec: dec, lst: lst, lat: lat)
            var altDeg = h.altDeg
            if altDeg < -1.6 { continue }
            // 大气折射：低空天体被抬升，恒星在低空看起来偏高、偏红
            if altDeg < 60 && altDeg > -1 {
                let r = 1.02 / tan((altDeg + 10.3 / (altDeg + 5.11)) * deg) / 60
                altDeg += min(0.62, max(0, r))
            }
            let X = airmass(altDeg: max(0.1, altDeg))
            let ext = 0.27 * (X - 1)
            let m = s.mag + ext
            let refracted = Horizontal(alt: altDeg * deg, az: h.az)
            positions.append(StarPosition(index: i, position: refracted, extinctedMag: m))
            if m <= limitMag && altDeg > 12 && altDeg < 78 && s.mag < 4.8 && s.con != 255 {
                var dAz = (h.az - centerAz).truncatingRemainder(dividingBy: 2 * .pi)
                if dAz > .pi { dAz -= 2 * .pi } else if dAz < -.pi { dAz += 2 * .pi }
                if abs(dAz) < 70 * deg { conCount[s.con, default: 0] += 1 }
            }
        }

        let names = StarCatalog.constellations
        let counts: [(String, Int)] = conCount
            .compactMap { k, v in
                guard v >= 2, Int(k) < names.count else { return nil }
                return (StarCatalog.constellationNames[names[Int(k)]] ?? names[Int(k)], v)
            }
            .sorted { $0.1 > $1.1 }

        let planets = planetPositions(jd: jd, T: T, lst: lst, lat: lat)

        return SkyFrame(date: date, jd: jd, lst: lst,
                        latDeg: place.latitude, lonDeg: place.longitude,
                        centerAz: centerAz, centerAlt: centerAlt, halfScale: halfScale,
                        sun: sun, moon: moon, moonPhase: phase, moonIllumination: illum,
                        planets: planets, stars: positions,
                        constellationCounts: counts, limitMag: limitMag, darkness: darkness)
    }

    // MARK: 时间与坐标

    static func julianDay(_ date: Date) -> Double {
        date.timeIntervalSince1970 / 86400 + 2440587.5
    }

    static func localSiderealTime(jd: Double, T: Double, lonDeg: Double) -> Double {
        let gmst = 280.46061837 + 360.98564736629 * (jd - j2000)
            + 0.000387933 * T * T - T * T * T / 38_710_000
        var a = (gmst + lonDeg) * deg
        a = a.truncatingRemainder(dividingBy: 2 * .pi)
        return a < 0 ? a + 2 * .pi : a
    }

    static func toHorizontal(ra: Double, dec: Double, lst: Double, lat: Double) -> Horizontal {
        let H = lst - ra
        let sd = sin(dec), cd = cos(dec), sp = sin(lat), cp = cos(lat)
        let sH = sin(H), cH = cos(H)
        let up = sd * sp + cd * cp * cH
        let east = -cd * sH
        let north = sd * cp - cd * sp * cH
        var az = atan2(east, north)
        if az < 0 { az += 2 * .pi }
        return Horizontal(alt: asin(max(-1, min(1, up))), az: az)
    }

    static func eclipticToEquatorial(lon: Double, lat: Double, T: Double) -> (ra: Double, dec: Double, lon: Double) {
        let eps = (23.439291 - 0.0130042 * T) * deg
        let x = cos(lat) * cos(lon)
        let y = cos(lat) * sin(lon)
        let z = sin(lat)
        let ye = y * cos(eps) - z * sin(eps)
        let ze = y * sin(eps) + z * cos(eps)
        return (atan2(ye, x), asin(max(-1, min(1, ze))), lon)
    }

    static func sunEcliptic(T: Double) -> (lon: Double, r: Double) {
        let d = T * 36525
        let L = (280.460 + 0.9856474 * d) * deg
        let g = (357.528 + 0.9856003 * d) * deg
        let lon = L + (1.915 * sin(g) + 0.020 * sin(2 * g)) * deg
        let r = 1.00014 - 0.01671 * cos(g) - 0.00014 * cos(2 * g)
        var a = lon.truncatingRemainder(dividingBy: 2 * .pi)
        if a < 0 { a += 2 * .pi }
        return (a, r)
    }

    /// 月球黄道坐标（Meeus 截断到主要周期项，误差 < 0.3°）
    static func moonEquatorial(T: Double, jd: Double) -> (ra: Double, dec: Double, lon: Double) {
        let d = jd - j2000
        let L0 = 218.316 + 13.176396 * d
        let M = (134.963 + 13.064993 * d) * deg
        let Ms = (357.529 + 0.98560028 * d) * deg
        let D = (297.850 + 12.190749 * d) * deg
        let F = (93.272 + 13.229350 * d) * deg
        var lon = L0 + 6.289 * sin(M) + 1.274 * sin(2 * D - M)
            + 0.658 * sin(2 * D) + 0.214 * sin(2 * M) - 0.186 * sin(Ms)
            - 0.114 * sin(2 * F) + 0.059 * sin(2 * D - 2 * M)
            + 0.057 * sin(2 * D - M - Ms) + 0.053 * sin(2 * D + M)
        let beta = (5.128 * sin(F) + 0.281 * sin(M + F) - 0.278 * sin(F - M)
            - 0.173 * sin(2 * D - F)) * deg
        lon = lon * deg
        lon = lon.truncatingRemainder(dividingBy: 2 * .pi)
        if lon < 0 { lon += 2 * .pi }
        return eclipticToEquatorial(lon: lon, lat: beta, T: T)
    }

    /// Kasten–Young 大气质量，用于消光与低空星变红
    static func airmass(altDeg: Double) -> Double {
        let a = max(0.1, altDeg)
        return 1 / (sin(a * deg) + 0.50572 * pow(a + 6.07995, -1.6364))
    }

    // MARK: 行星（JPL 近似轨道元素，1800–2050 精度约 1 角分）

    private struct Elements {
        let a: Double, ad: Double, e: Double, ed: Double, i: Double, id: Double
        let L: Double, Ld: Double, peri: Double, perid: Double, node: Double, noded: Double
        let H0: Double, color: (Double, Double, Double), name: String
    }

    private static let elements: [Elements] = [
        // a(AU), ȧ, e, ė, I, İ, L, L̇, ϖ, ϖ̇, Ω, Ω̇, 绝对亮度项, 颜色, 名称（每儒略世纪）
        Elements(a: 0.38709927, ad: 0.00000037, e: 0.20563593, ed: 0.00001906,
                 i: 7.00497902, id: -0.00594749, L: 252.25032350, Ld: 149472.67411175,
                 peri: 77.45779628, perid: 0.16047689, node: 48.33076593, noded: -0.12534081,
                 H0: 3.1, color: (0.86, 0.84, 0.80), name: "水星"),
        Elements(a: 0.72333566, ad: 0.00000390, e: 0.00677672, ed: -0.00004107,
                 i: 3.39467605, id: -0.00078890, L: 181.97909950, Ld: 58517.81538729,
                 peri: 131.60246718, perid: 0.00268329, node: 76.67984255, noded: -0.27769418,
                 H0: -0.9, color: (1.0, 0.96, 0.86), name: "金星"),
        Elements(a: 1.00000261, ad: 0.00000562, e: 0.01671123, ed: -0.00004392,
                 i: -0.00001531, id: -0.01294668, L: 100.46457166, Ld: 35999.37244981,
                 peri: 102.93768193, perid: 0.32327364, node: 0.0, noded: 0.0,
                 H0: 0, color: (0, 0, 0), name: "地球"),
        Elements(a: 1.52371034, ad: 0.00001847, e: 0.09339410, ed: 0.00007882,
                 i: 1.84969142, id: -0.00813131, L: -4.55343205, Ld: 19140.30268499,
                 peri: -23.94362959, perid: 0.44441088, node: 49.55953891, noded: -0.29257343,
                 H0: -1.5, color: (1.0, 0.63, 0.42), name: "火星"),
        Elements(a: 5.20288700, ad: -0.00011607, e: 0.04838624, ed: -0.00013253,
                 i: 1.30439695, id: -0.00183714, L: 34.39644051, Ld: 3034.74612775,
                 peri: 14.72847983, perid: 0.21252668, node: 100.47390909, noded: 0.20469106,
                 H0: -9.4, color: (1.0, 0.91, 0.76), name: "木星"),
        Elements(a: 9.53667594, ad: -0.00125060, e: 0.05386179, ed: -0.00050991,
                 i: 2.48599187, id: 0.00193609, L: 49.95424423, Ld: 1222.49362201,
                 peri: 92.59887831, perid: -0.41897216, node: 113.66242448, noded: -0.28867794,
                 H0: -8.9, color: (1.0, 0.87, 0.62), name: "土星"),
    ]

    private static func heliocentric(_ el: Elements, T: Double) -> (x: Double, y: Double, z: Double, r: Double) {
        let a = el.a + el.ad * T, e = el.e + el.ed * T
        let I = (el.i + el.id * T) * deg
        let L = (el.L + el.Ld * T) * deg
        let peri = (el.peri + el.perid * T) * deg
        let node = (el.node + el.noded * T) * deg
        var M = (L - peri).truncatingRemainder(dividingBy: 2 * .pi)
        if M < -.pi { M += 2 * .pi } else if M > .pi { M -= 2 * .pi }
        var E = M + e * sin(M)
        for _ in 0..<6 { E -= (E - e * sin(E) - M) / (1 - e * cos(E)) }
        let xp = a * (cos(E) - e), yp = a * sqrt(1 - e * e) * sin(E)
        let w = peri - node
        let cw = cos(w), sw = sin(w), cO = cos(node), sO = sin(node), cI = cos(I), sI = sin(I)
        let x = (cw * cO - sw * sO * cI) * xp + (-sw * cO - cw * sO * cI) * yp
        let y = (cw * sO + sw * cO * cI) * xp + (-sw * sO + cw * cO * cI) * yp
        let z = (sw * sI) * xp + (cw * sI) * yp
        return (x, y, z, a * (1 - e * cos(E)))
    }

    private static func planetPositions(jd: Double, T: Double, lst: Double, lat: Double) -> [PlanetPosition] {
        let earth = heliocentric(elements[2], T: T)
        let eps = (23.439291 - 0.0130042 * T) * deg
        var out: [PlanetPosition] = []
        for el in elements where el.name != "地球" {
            let p = heliocentric(el, T: T)
            let gx = p.x - earth.x, gy = p.y - earth.y, gz = p.z - earth.z
            let delta = sqrt(gx * gx + gy * gy + gz * gz)
            let xe = gx
            let ye = gy * cos(eps) - gz * sin(eps)
            let ze = gy * sin(eps) + gz * cos(eps)
            let ra = atan2(ye, xe)
            let dec = atan2(ze, sqrt(xe * xe + ye * ye))
            let h = toHorizontal(ra: ra, dec: dec, lst: lst, lat: lat)
            guard h.altDeg > -1.5 else { continue }
            // 相位修正：内行星有盈亏，外行星冲日时最亮
            let cosPhase = max(-1, min(1, (p.r * p.r + delta * delta - 1) / (2 * p.r * delta)))
            let lit = (1 + cosPhase) / 2
            let phaseLoss = (el.name == "金星" ? 1.1 : el.name == "水星" ? 0.7 : 0.35) * (1 - lit)
            let mag = el.H0 + 5 * log10(max(0.01, p.r * delta)) + phaseLoss
            if mag > 6.2 { continue }
            out.append(PlanetPosition(name: el.name, position: h, mag: mag, color: el.color))
        }
        return out
    }

    static func clamp(_ x: Double, _ lo: Double, _ hi: Double) -> Double {
        min(hi, max(lo, x))
    }

    /// B-V 色指数 → 黑体近似 RGB（Ballesteros 温度公式 + 分段近似）
    static func starColor(bv: Double) -> (Double, Double, Double) {
        let b = max(-0.4, min(2.0, bv))
        let t = 4600 * (1 / (0.92 * b + 1.7) + 1 / (0.92 * b + 0.62))
        let k = max(1000, min(40000, t)) / 100
        let r: Double, g: Double, bl: Double
        if k <= 66 {
            r = 1
            g = max(0, min(1, (99.4708025861 * log(k) - 161.1195681661) / 255))
        } else {
            r = max(0, min(1, (329.698727446 * pow(k - 60, -0.1332047592)) / 255))
            g = max(0, min(1, (288.1221695283 * pow(k - 60, -0.0755148492)) / 255))
        }
        if k >= 66 { bl = 1 }
        else if k <= 19 { bl = 0 }
        else { bl = max(0, min(1, (138.5177312231 * log(k - 10) - 305.0447927307) / 255)) }
        // 目视星色比黑体色淡，往白里收一半
        return (0.5 + r * 0.5, 0.5 + g * 0.5, 0.5 + bl * 0.5)
    }
}

// MARK: - 关键时刻（日出 / 日落 / 月升 / 月落）实时计算

/// 当前时刻当地的关键天象事件。全部由本机星历推算，不依赖天气接口的刷新频率，
/// 所以「下一次日出 / 日落」始终是最新的，而不是上次联网时刻算出来的旧值。
struct SkyEvents {
    let sunrise: Date        // 当天日出（太阳中心落到地平线 -0.833°）
    let sunset: Date         // 当天日落
    let nextSunrise: Date    // 下一次日出（今天或明天）
    let nextSunset: Date     // 下一次日落
    let moonrise: Date?      // 接下来一次的月升
    let moonset: Date?       // 接下来一次的月落
    let isDay: Bool          // 太阳是否在地平线之上（-0.833°）
}

extension Astronomy {
    /// 太阳高度角（度），本机历元，供相位与关键时刻推算
    static func sunAltitude(date: Date = Date(), place: Place) -> Double {
        altitude(0, date: date, place: place)
    }

    /// 月亮高度角（度）
    static func moonAltitude(date: Date = Date(), place: Place) -> Double {
        altitude(1, date: date, place: place)
    }

    /// 实时天空相位：由太阳真实地平高度 + 升落趋势决定，而非天气接口缓存的日出日落插值。
    /// 这样日落那一刻画面就切到晚霞，而不是等下次联网。
    static func skyState(date: Date = Date(), place: Place) -> SkyState {
        skyState(date: date, frame: frame(date: date, place: place), place: place)
    }

    static func skyState(date: Date, frame f: SkyFrame, place: Place) -> SkyState {
        let alt = f.sun.altDeg
        let earlier = altitude(0, date: date.addingTimeInterval(-300), place: place)
        let rising = alt > earlier
        let phase: SkyPhase
        if alt > 6 { phase = .day }
        else if alt > -0.833 { phase = rising ? .dawn : .dusk }
        else { phase = .night }
        let warmth = clamp((6 - alt) / 12, 0, 1)        // 贴近地平线 → 1
        let stars = f.darkness                              // 暮光连续淡入，星点同步出现
        let alt01 = clamp((alt + 0.833) / 90.833, 0, 1)
        return SkyState(phase: phase, isSun: alt > -0.833,
                        x: 0.5, y: 0.5, altitude: alt01,
                        warmth: warmth, stars: stars)
    }

    /// 当地当天与接来下的太阳 / 月亮事件。结果按 5 分钟粒度缓存，多屏共用。
    static func dayEvents(date: Date = Date(), place: Place) -> SkyEvents {
        let key = "\(Int(date.timeIntervalSince1970 / 300))|\(Int(place.latitude * 1000))|\(Int(place.longitude * 1000))"
        if key == cachedEventsKey, let e = cachedEvents { return e }
        let t0 = -0.833 * .pi / 180
        let noon = solarNoon(date: date, place: place)
        let start = noon.addingTimeInterval(-12 * 3600)
        let sunrise = crossing(0, threshold: t0, after: start, place: place, upward: true)
        let sunset = crossing(0, threshold: t0, after: start, place: place, upward: false)
        let nextSunrise = crossing(0, threshold: t0, after: date, place: place, upward: true)
        let nextSunset = crossing(0, threshold: t0, after: date, place: place, upward: false)
        let moonrise = crossing(1, threshold: 0, after: date, place: place, upward: true)
        let moonset = crossing(1, threshold: 0, after: date, place: place, upward: false)
        let isDay = altitude(0, date: date, place: place) > t0
        let e = SkyEvents(
            sunrise: sunrise ?? date, sunset: sunset ?? date,
            nextSunrise: nextSunrise ?? date.addingTimeInterval(86400),
            nextSunset: nextSunset ?? date.addingTimeInterval(86400),
            moonrise: moonrise, moonset: moonset, isDay: isDay)
        cachedEventsKey = key
        cachedEvents = e
        return e
    }

    // MARK: 私有求解

    private static var cachedEventsKey = ""
    private static var cachedEvents: SkyEvents?

    /// body: 0 = 太阳，1 = 月亮
    private static func altitude(_ body: Int, date: Date, place: Place) -> Double {
        let jd = date.timeIntervalSince1970 / 86400 + 2440587.5
        let T = (jd - j2000) / 36525
        let lat = place.latitude * deg
        let lst = localSiderealTime(jd: jd, T: T, lonDeg: place.longitude)
        if body == 0 {
            let (lon, _) = sunEcliptic(T: T)
            let eq = eclipticToEquatorial(lon: lon, lat: 0, T: T)
            return toHorizontal(ra: eq.ra, dec: eq.dec, lst: lst, lat: lat).altDeg
        } else {
            let eq = moonEquatorial(T: T, jd: jd)
            return toHorizontal(ra: eq.ra, dec: eq.dec, lst: lst, lat: lat).altDeg
        }
    }

    /// 当地真太阳正午（太阳高度最大的时刻），用于锁定「当天」的日出日落
    private static func solarNoon(date: Date, place: Place) -> Date {
        let base = date.timeIntervalSince1970
        var best = base, bestAlt = -90.0
        var t = base - 12 * 3600
        let end = base + 12 * 3600
        while t <= end {
            let a = altitude(0, date: Date(timeIntervalSince1970: t), place: place)
            if a > bestAlt { bestAlt = a; best = t }
            t += 600
        }
        return Date(timeIntervalSince1970: best)
    }

    /// 在 [after, after+36h] 内，寻找 body 高度穿越 threshold 的时刻（上升/下降由 upward 决定），二分收敛到秒级
    private static func crossing(_ body: Int, threshold: Double, after: Date, place: Place, upward: Bool) -> Date? {
        let afterT = after.timeIntervalSince1970
        var t = afterT
        var prevT = t
        var prevD = altitude(body, date: Date(timeIntervalSince1970: t), place: place) - threshold
        let limit: TimeInterval = 36 * 3600
        while t - afterT < limit {
            t += 600
            let d = altitude(body, date: Date(timeIntervalSince1970: t), place: place) - threshold
            let crossed = upward ? (prevD < 0 && d >= 0) : (prevD > 0 && d <= 0)
            if crossed {
                var lo = prevT, hi = t
                for _ in 0..<26 {
                    let mid = lo + (hi - lo) / 2
                    let m = altitude(body, date: Date(timeIntervalSince1970: mid), place: place) - threshold
                    if upward ? (m < 0) : (m > 0) { lo = mid } else { hi = mid }
                }
                return Date(timeIntervalSince1970: lo + (hi - lo) / 2)
            }
            prevD = d; prevT = t
        }
        return nil
    }
}
