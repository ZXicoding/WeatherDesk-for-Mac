import Foundation
import AppKit

// MARK: - WMO 天气码

enum Condition: String, CaseIterable, Codable {
    case clear
    case partlyCloudy
    case cloudy
    case overcast
    case fog
    case drizzle
    case rain
    case heavyRain
    case sleet
    case snow
    case thunder

    var label: String {
        switch self {
        case .clear:       return "晴"
        case .partlyCloudy: return "少云"
        case .cloudy:      return "多云"
        case .overcast:    return "阴"
        case .fog:         return "雾"
        case .drizzle:     return "毛毛雨"
        case .rain:        return "下雨"
        case .heavyRain:   return "大雨"
        case .sleet:       return "雨夹雪"
        case .snow:        return "下雪"
        case .thunder:     return "雷阵雨"
        }
    }

    var symbol: String {
        switch self {
        case .clear:        return "sun.max.fill"
        case .partlyCloudy: return "cloud.sun.fill"
        case .cloudy:       return "cloud.fill"
        case .overcast:     return "smoke.fill"
        case .fog:          return "cloud.fog.fill"
        case .drizzle:      return "cloud.drizzle.fill"
        case .rain:         return "cloud.rain.fill"
        case .heavyRain:    return "cloud.heavyrain.fill"
        case .sleet:        return "cloud.sleet.fill"
        case .snow:         return "cloud.snow.fill"
        case .thunder:      return "cloud.bolt.rain.fill"
        }
    }

    var isRainy: Bool {
        self == .drizzle || self == .rain || self == .heavyRain || self == .sleet || self == .thunder
    }

    var isSnowy: Bool { self == .snow || self == .sleet }
    var isThunder: Bool { self == .thunder }
    var isFoggy: Bool { self == .fog }

    /// 基础云层数量（会再叠加实际云量）
    var cloudBase: Int {
        switch self {
        case .clear: return 0
        case .partlyCloudy: return 2
        case .cloudy: return 4
        case .overcast: return 7
        case .fog: return 3
        case .drizzle: return 5
        case .rain: return 6
        case .heavyRain: return 8
        case .sleet: return 7
        case .snow: return 6
        case .thunder: return 8
        }
    }
}

/// WMO 4677 天气码 → 视觉状态
func condition(for code: Int) -> Condition {
    switch code {
    case 0:          return .clear
    case 1:          return .partlyCloudy
    case 2:          return .cloudy
    case 3:          return .overcast
    case 45, 48:     return .fog
    case 51, 53, 55: return .drizzle
    case 56, 57:     return .sleet
    case 61, 63:     return .rain
    case 65:         return .heavyRain
    case 66, 67:     return .sleet
    case 71, 73, 75, 77: return .snow
    case 80, 81:     return .rain
    case 82:         return .heavyRain
    case 85, 86:     return .snow
    case 95, 96, 99: return .thunder
    default:         return .cloudy
    }
}

// MARK: - 天空相位与太阳位置

enum SkyPhase: String {
    case night
    case dawn
    case day
    case dusk

    var label: String {
        switch self {
        case .night: return "夜"
        case .dawn:  return "日出"
        case .day:   return "白天"
        case .dusk:  return "日落"
        }
    }
}

struct SkyState {
    var phase: SkyPhase
    var isSun: Bool
    /// 0 ... 1，屏幕宽度比例
    var x: CGFloat
    /// 0 ... 1，从屏幕底部算起的高度比例
    var y: CGFloat
    /// 0 ... 1，天体高度
    var altitude: Double
    /// 0 ... 1，靠近地平线的程度，用来加暖色
    var warmth: Double
    /// 0 ... 1，星空可见度
    var stars: Double
}

/// 可编码：最近一次成功的天气会落到 UserDefaults，供开机首帧离线渲染。
struct Weather: Codable {
    var place: Place
    var condition: Condition
    var code: Int
    var temperature: Double
    var apparent: Double
    var humidity: Int
    var windSpeed: Double
    var windDirection: Double
    var precipitation: Double
    var cloudCover: Int
    var isDay: Bool
    var sunrise: Date
    var sunset: Date
    var nextSunrise: Date
    var observedAt: Date
    var fetchedAt: Date
    var timeZoneName: String
    var utcOffset: Int
    /// 演示 / 预览：日出日落是人工设定的，天体位置用插值；实时数据才套用天文坐标
    var simulated: Bool = false

    var localTimeZone: TimeZone { TimeZone(secondsFromGMT: utcOffset) ?? .current }

    /// 是否属于「通透好天」：无降水、无雾、云量低、天气码为晴或少云。
    ///
    /// 2 小时档位底图按它在两套素材里二选一：
    /// `scene-hHH-sun.jpg`（蓝天通透、艳阳版）/ `scene-hHH.jpg`（柔和灰调、阴天版）。
    /// 阴、多云、雾、雨雪一律走后者；不限 isDay —— 晴夜也该是清朗深蓝，
    /// 而不是灰蒙蒙一片。只影响底图，粒子层照旧按天气出云、雨、雪、雾。
    var isSunnyScene: Bool {
        guard precipitation <= 0.01,
              !condition.isRainy, !condition.isSnowy, !condition.isFoggy else { return false }
        switch condition {
        case .clear:        return cloudCover <= 60
        case .partlyCloudy: return cloudCover <= 45
        default:            return false
        }
    }

    /// 用当地日出 / 日落时间算出此刻太阳或月亮在画面里的位置。
    /// 这是「日落时背景就是日落」的关键：不依赖天气接口的 is_day 布尔值，
    /// 而是按真实天文时间在两次刷新之间连续推进。
    func sky(at now: Date = Date()) -> SkyState {
        let dayLen = max(3600, sunset.timeIntervalSince(sunrise))
        if now >= sunrise && now < sunset {
            let t = min(1, max(0, now.timeIntervalSince(sunrise) / dayLen))
            let alt = max(0, sin(Double.pi * t))
            var phase: SkyPhase = .day
            if now.timeIntervalSince(sunrise) < 45 * 60 { phase = .dawn }
            else if sunset.timeIntervalSince(now) < 50 * 60 { phase = .dusk }
            return SkyState(phase: phase, isSun: true,
                            x: 0.10 + 0.80 * CGFloat(t),
                            y: 0.10 + CGFloat(alt) * 0.70,
                            altitude: alt,
                            warmth: max(0, 1 - alt * 2.4),
                            stars: 0)
        }

        let nightLen = max(3600, nextSunrise.timeIntervalSince(sunset))
        let nightStart = now >= sunset ? sunset : sunset.addingTimeInterval(-nightLen)
        let nightEnd = now >= sunset ? nextSunrise : sunrise
        let span = max(3600, nightEnd.timeIntervalSince(nightStart))
        let t = min(1, max(0, now.timeIntervalSince(nightStart) / span))
        let alt = max(0, sin(Double.pi * t))
        var phase: SkyPhase = .night
        if now.timeIntervalSince(nightStart) < 35 * 60 { phase = .dusk }
        else if nightEnd.timeIntervalSince(now) < 45 * 60 { phase = .dawn }
        return SkyState(phase: phase, isSun: false,
                        x: 0.10 + 0.80 * CGFloat(t),
                        y: 0.16 + CGFloat(alt) * 0.60,
                        altitude: alt,
                        warmth: max(0, 1 - alt * 2.4),
                        stars: 1)
    }

    var observedTimeString: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        f.timeZone = localTimeZone
        return f.string(from: observedAt)
    }
}

// MARK: - 配色

extension NSColor {
    static func rgb(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> NSColor {
        NSColor(calibratedRed: r, green: g, blue: b, alpha: a)
    }

    func mixed(_ other: NSColor, _ t: CGFloat) -> NSColor {
        guard let a = usingColorSpace(.deviceRGB), let b = other.usingColorSpace(.deviceRGB) else { return self }
        let k = min(1, max(0, t))
        return NSColor(calibratedRed: a.redComponent + (b.redComponent - a.redComponent) * k,
                       green: a.greenComponent + (b.greenComponent - a.greenComponent) * k,
                       blue: a.blueComponent + (b.blueComponent - a.blueComponent) * k,
                       alpha: a.alphaComponent + (b.alphaComponent - a.alphaComponent) * k)
    }
}

struct Palette {
    var top: NSColor
    var mid: NSColor
    var bottom: NSColor
    var body: NSColor
    var glow: NSColor
    var cloud: NSColor

    static func make(state: SkyState, condition c: Condition, cloudCover: Int) -> Palette {
        var top = NSColor.clear, mid = NSColor.clear, bottom = NSColor.clear
        switch state.phase {
        case .day:
            top = .rgb(0.14, 0.43, 0.78); mid = .rgb(0.44, 0.71, 0.93); bottom = .rgb(0.85, 0.94, 0.99)
        case .dawn:
            top = .rgb(0.19, 0.24, 0.46); mid = .rgb(0.88, 0.48, 0.42); bottom = .rgb(1.00, 0.76, 0.55)
        case .dusk:
            top = .rgb(0.22, 0.15, 0.36); mid = .rgb(0.94, 0.40, 0.28); bottom = .rgb(1.00, 0.66, 0.34)
        case .night:
            top = .rgb(0.018, 0.036, 0.10); mid = .rgb(0.055, 0.095, 0.20); bottom = .rgb(0.11, 0.17, 0.29)
        }

        func blend(_ t: CGFloat, _ a: NSColor, _ b: NSColor, _ c: NSColor) {
            top = top.mixed(a, t); mid = mid.mixed(b, t); bottom = bottom.mixed(c, t)
        }

        // 云量先压一层灰
        if c != .fog && c != .snow {
            let cloudT = CGFloat(min(90, max(0, cloudCover))) / 100 * 0.42
            blend(cloudT, .rgb(0.28, 0.34, 0.42), .rgb(0.48, 0.55, 0.62), .rgb(0.70, 0.77, 0.82))
        }

        switch c {
        case .clear, .partlyCloudy, .cloudy, .overcast: break
        case .drizzle: blend(0.42, .rgb(0.15, 0.21, 0.28), .rgb(0.29, 0.38, 0.44), .rgb(0.47, 0.55, 0.60))
        case .rain:    blend(0.58, .rgb(0.13, 0.18, 0.25), .rgb(0.26, 0.34, 0.41), .rgb(0.43, 0.51, 0.57))
        case .heavyRain, .thunder:
                       blend(0.78, .rgb(0.055, 0.08, 0.12), .rgb(0.13, 0.18, 0.24), .rgb(0.24, 0.30, 0.36))
        case .sleet:   blend(0.55, .rgb(0.24, 0.32, 0.40), .rgb(0.45, 0.55, 0.62), .rgb(0.70, 0.78, 0.83))
        case .snow:    blend(0.58, .rgb(0.40, 0.49, 0.58), .rgb(0.68, 0.77, 0.84), .rgb(0.90, 0.94, 0.97))
        case .fog:     blend(0.62, .rgb(0.55, 0.61, 0.65), .rgb(0.74, 0.79, 0.82), .rgb(0.87, 0.90, 0.91))
        }

        // 靠近地平线时额外加一点暖光
        if state.isSun && (state.phase == .dawn || state.phase == .dusk) {
            blend(CGFloat(state.warmth) * 0.28,
                  .rgb(0.32, 0.20, 0.38), .rgb(0.98, 0.52, 0.36), .rgb(1.00, 0.76, 0.48))
        }

        let body: NSColor
        if state.isSun {
            body = .rgb(1.0, 0.97, 0.84)
                .mixed(.rgb(1.0, 0.62, 0.36), CGFloat(state.warmth) * 0.85)
        } else {
            body = .rgb(0.90, 0.93, 1.00)
        }

        let cloud: NSColor
        switch c {
        case .heavyRain, .thunder: cloud = .rgb(0.30, 0.34, 0.40)
        case .rain, .drizzle, .sleet: cloud = .rgb(0.33, 0.38, 0.44)
        case .snow: cloud = .rgb(0.82, 0.88, 0.93)
        case .fog: cloud = .rgb(0.86, 0.89, 0.91)
        default:
            switch state.phase {
            case .day:   cloud = .rgb(1.0, 1.0, 1.0)
            case .dawn, .dusk: cloud = .rgb(1.0, 0.83, 0.70)
            case .night: cloud = .rgb(0.40, 0.46, 0.60)
            }
        }

        return Palette(top: top, mid: mid, bottom: bottom,
                       body: body,
                       glow: body.withAlphaComponent(state.isSun ? 0.55 : 0.28),
                       cloud: cloud)
    }
}
