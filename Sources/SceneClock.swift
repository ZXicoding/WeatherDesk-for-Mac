import Foundation

/// 当地时间按 2 小时分档：00、02、04 … 22，共 12 档，每档一张实景底图。
///
/// 以前只有「白天 / 日出日落 / 夜」三档，日落后到次日日出前（冬天长达 14 小时）
/// 一直是同一张夜景，所以下午和深夜看起来完全一样。现在改成 12 档，
/// 每到偶数整点自动换图；档位跟**当地挂钟**走，换 IP 到别的时区也正确。
enum SceneClock {
    static let slotHours = 2
    static let slotCount = 24 / slotHours
    static let allSlots = stride(from: 0, to: 24, by: slotHours).map { $0 }

    /// Open-Meteo 的 timezone=auto 给的是 IANA 名（含夏令时规则），优先用它；
    /// 老缓存只有 utcOffset 时用固定偏移兜底。
    static func timeZone(_ w: Weather) -> TimeZone {
        TimeZone(identifier: w.timeZoneName) ?? w.localTimeZone
    }

    /// 当前所处的 2 小时档位起点小时数：0 / 2 / … / 22
    static func slot(date: Date = Date(), timeZone: TimeZone = .current) -> Int {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let h = cal.component(.hour, from: date)
        return (h / slotHours) * slotHours
    }

    /// 档位对应的底图主名，例如 0 → scene-h00，22 → scene-h22
    static func name(_ slot: Int) -> String {
        let h = ((slot % 24) + 24) % 24
        return String(format: "scene-h%02d", (h / slotHours) * slotHours)
    }

    /// 距离下一档还有多少秒（唤醒 / 定时器对齐用）
    static func secondsToNextSlot(date: Date = Date(),
                                  timeZone: TimeZone = .current) -> TimeInterval {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let h = cal.component(.hour, from: date)
        let m = cal.component(.minute, from: date)
        let s = cal.component(.second, from: date)
        let start = (h / slotHours) * slotHours
        let elapsed = (h - start) * 3600 + m * 60 + s
        return TimeInterval(slotHours * 3600 - elapsed) + 0.5
    }

    /// 档位文字，例如 "00:00–02:00"
    static func label(_ slot: Int) -> String {
        let h = ((slot % 24) + 24) % 24
        return String(format: "%02d:00–%02d:00", h, (h + slotHours) % 24)
    }

    /// 雨雪 / 雾的天气专属覆盖标签
    static func weatherTag(_ c: Condition) -> String? {
        switch c {
        case .drizzle, .rain, .heavyRain, .thunder, .fog: return "rain"
        case .snow, .sleet:                               return "snow"
        default:                                          return nil
        }
    }

    /// 某档位在某天气下的底图候选名，按优先级排列。纯函数，自检可直接调用。
    ///
    /// 晴天（isSunny）优先 `scene-hHH-sun.jpg` 通透版；雨雪 / 雾优先
    /// `scene-hHH-rain/snow.jpg`；其余用主图。素材缺失时逐层回退主图，
    /// 不会黑屏。
    static func names(slot: Int, condition c: Condition, isSunny: Bool) -> [String] {
        let base = name(slot)
        if let tag = weatherTag(c) { return ["\(base)-\(tag)", base] }
        if isSunny { return ["\(base)-sun", base] }
        return [base]
    }
}
