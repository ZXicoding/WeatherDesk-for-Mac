import Foundation
import AppKit
import CoreLocation

@main
struct Verify {
    private static var passed = 0
    private static var failed = 0

    private static func ok(_ name: String, _ condition: @autoclosure () -> Bool) {
        if condition() {
            passed += 1
            print("  ✓ \(name)")
        } else {
            failed += 1
            print("  ✗ \(name)")
        }
    }

    private static func weather(rise: TimeInterval, set: TimeInterval, next: TimeInterval,
                                cond: Condition = .clear) -> Weather {
        let now = Date()
        return Weather(
            place: .fallback, condition: cond, code: 0,
            temperature: 20, apparent: 19, humidity: 50,
            windSpeed: 10, windDirection: 180,
            precipitation: 0, cloudCover: 10, isDay: true,
            sunrise: now.addingTimeInterval(rise),
            sunset: now.addingTimeInterval(set),
            nextSunrise: now.addingTimeInterval(next),
            observedAt: now, fetchedAt: now,
            timeZoneName: "Asia/Shanghai", utcOffset: 28800)
    }

    private static func brightness(_ c: NSColor) -> CGFloat {
        guard let x = c.usingColorSpace(.deviceRGB) else { return 0 }
        return x.redComponent + x.greenComponent + x.blueComponent
    }

    static func main() {
        print("天气桌面 · 数据层自检")

        print("— WMO 天气码映射")
        ok("0 晴", condition(for: 0) == .clear)
        ok("2 多云", condition(for: 2) == .cloudy)
        ok("3 阴", condition(for: 3) == .overcast)
        ok("45 雾", condition(for: 45) == .fog)
        ok("61 下雨", condition(for: 61) == .rain)
        ok("65 大雨", condition(for: 65) == .heavyRain)
        ok("73 下雪", condition(for: 73) == .snow)
        ok("82 大雨", condition(for: 82) == .heavyRain)
        ok("95 雷阵雨", condition(for: 95) == .thunder)
        ok("雨会生成雨粒子", condition(for: 63).isRainy && condition(for: 95).isRainy)
        ok("雪会生成雪粒子", condition(for: 75).isSnowy)

        print("— 太阳 / 月亮实时相位")
        let day = weather(rise: -4 * 3600, set: 4 * 3600, next: 20 * 3600).sky()
        ok("正午是白天且是太阳", day.phase == .day && day.isSun)
        ok("正午太阳高度接近最高", day.altitude > 0.98 && day.y > 0.75)

        let dusk = weather(rise: -9 * 3600, set: 9 * 60, next: 15 * 3600).sky()
        ok("日落前判定为 dusk", dusk.phase == .dusk && dusk.isSun)
        ok("日落时太阳贴近地平线", dusk.y < 0.32 && dusk.warmth > 0.7)

        let dawn = weather(rise: 20 * 60, set: -11 * 3600, next: 20 * 60).sky()
        ok("日出前判定为 dawn", dawn.phase == .dawn)

        let night = weather(rise: -12 * 3600, set: -2 * 3600, next: 8 * 3600).sky()
        ok("入夜后是月亮", night.phase == .night && !night.isSun)
        ok("夜晚显示星空", night.stars == 1)

        let sunsetDemo = Demo.sunset.weather().sky()
        ok("日落演示进入晚霞画面", sunsetDemo.phase == .dusk && sunsetDemo.isSun)
        let nightDemo = Demo.night.weather().sky()
        ok("夜晚演示出现月亮星空", nightDemo.phase == .night && !nightDemo.isSun)

        print("— 配色")
        let dayState = weather(rise: -4 * 3600, set: 4 * 3600, next: 20 * 3600).sky()
        let clearPal = Palette.make(state: dayState, condition: .clear, cloudCover: 0)
        let rainPal = Palette.make(state: dayState, condition: .heavyRain, cloudCover: 95)
        ok("暴雨天空比晴天更暗", brightness(rainPal.bottom) < brightness(clearPal.bottom))
        let nightPal = Palette.make(state: night, condition: .clear, cloudCover: 0)
        ok("夜空比白天天更暗", brightness(nightPal.top) < brightness(clearPal.top))
        let duskPal = Palette.make(state: dusk, condition: .clear, cloudCover: 0)
        ok("日落比白天更偏红", duskPal.mid.redComponent > clearPal.mid.redComponent)

        print("— 请求与解析")
        let url = WeatherService.forecastURL(for: .fallback).absoluteString
        ok("请求带经纬度", url.contains("latitude=31.2304") && url.contains("longitude=121.4737"))
        ok("请求带日出日落与时区", url.contains("daily=sunrise") && url.contains("timezone=auto"))
        ok("请求带全部实况字段", url.contains("weather_code") && url.contains("wind_speed_10m"))

        let df = DateFormatter()
        df.dateFormat = "yyyy-MM-dd"
        df.timeZone = TimeZone(secondsFromGMT: 28800)
        df.locale = Locale(identifier: "en_US_POSIX")
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = df.timeZone!
        func dayString(_ offset: Int) -> String {
            let d = cal.date(byAdding: .day, value: offset, to: Date())!
            return df.string(from: d)
        }
        let days = [-1, 0, 1, 2].map(dayString)
        let canned: [String: Any] = [
            "utc_offset_seconds": 28800,
            "timezone": "Asia/Shanghai",
            "current": [
                "time": days[1] + "T18:45",
                "temperature_2m": 15.7,
                "apparent_temperature": 14.2,
                "relative_humidity_2m": 62,
                "is_day": 0,
                "precipitation": 0.4,
                "weather_code": 63,
                "cloud_cover": 88,
                "wind_speed_10m": 12.4,
                "wind_direction_10m": 210,
            ],
            "daily": [
                "sunrise": days.map { $0 + "T06:24" },
                "sunset": days.map { $0 + "T17:08" },
            ],
        ]
        let parsed = WeatherService.parse(json: canned, place: .fallback)
        ok("能解析实时天气 JSON", parsed != nil)
        if let p = parsed {
            ok("温度 / 天气码正确", abs(p.temperature - 15.7) < 0.01 && p.condition == .rain)
            ok("日出早于日落、次日出更晚", p.sunrise < p.sunset && p.nextSunrise > p.sunset)
            ok("当地时区正确", p.utcOffset == 28800 && p.timeZoneName == "Asia/Shanghai")
            ok("解析出的日出时刻判为 dawn",
               p.sky(at: p.sunrise.addingTimeInterval(10 * 60)).phase == .dawn)
            ok("解析出的日落时刻判为 dusk",
               p.sky(at: p.sunset.addingTimeInterval(-10 * 60)).phase == .dusk)
        }

        print("— 定位与设置")
        let place = Place(name: "上海", region: "中国", latitude: 31.23, longitude: 121.47)
        let data = try! JSONEncoder().encode(place)
        let back = try! JSONDecoder().decode(Place.self, from: data)
        ok("城市可持久化往返", back == place && back.display == "上海 · 中国")
        ok("默认同步间隔 10 分钟", Settings.shared.refreshMinutes == 10)

        print("— 真实星图与天文")
        func utc(_ y: Int, _ m: Int, _ d: Int, _ h: Int, _ minute: Int = 0) -> Date {
            var c = DateComponents()
            c.timeZone = TimeZone(secondsFromGMT: 0)!
            c.year = y; c.month = m; c.day = d; c.hour = h; c.minute = minute
            return Calendar(identifier: .gregorian).date(from: c)!
        }
        ok("内置星表含八千余颗肉眼可见恒星", StarCatalog.stars.count > 8000)
        ok("88 星座与连线齐全",
           StarCatalog.constellations.count == 88 && StarCatalog.lines.count > 600)
        let brightest = StarCatalog.stars[0]
        ok("最亮星为天狼星", brightest.mag < -1.3
            && abs(brightest.ra * 12 / .pi - 6.752) < 0.02)
        let polaris = StarCatalog.stars.first { $0.hip == 11767 }!
        ok("北极星赤纬 ≈ 89.26°", abs(polaris.dec * 180 / .pi - 89.264) < 0.02)

        let summer = Astronomy.frame(date: utc(2026, 6, 21, 4), place: .fallback)
        let winter = Astronomy.frame(date: utc(2026, 12, 21, 4), place: .fallback)
        ok("上海夏至正午太阳高度 ≈ 82°", abs(summer.sun.altDeg - 82.2) < 0.8)
        ok("上海冬至正午太阳高度 ≈ 35°", abs(winter.sun.altDeg - 35.3) < 0.8)
        let newMoon = Astronomy.frame(date: utc(2000, 1, 6, 18, 14), place: .fallback).moonPhase
        ok("2000-01-06 18:14 UTC 为朔月", newMoon < 0.01 || newMoon > 0.99)

        let tonightFrame = Astronomy.frame(date: utc(2026, 11, 6, 13, 30), place: .fallback)
        let lat = 31.2304 * .pi / 180
        let hourAngle = tonightFrame.lst - polaris.ra
        let polAlt = asin(sin(polaris.dec) * sin(lat)
                          + cos(polaris.dec) * cos(lat) * cos(hourAngle)) * 180 / .pi
        ok("北极星高度 ≈ 观测地纬度", abs(polAlt - 31.2304) < 1.2)
        ok("行星与恒星共用同一时刻", tonightFrame.planets.contains { $0.name == "土星" })

        let size = CGSize(width: 1440, height: 900)
        let starCount = tonightFrame.projectedStars(size: size).count
        ok("今夜画面里有数百颗真实恒星", starCount > 300 && starCount < 2500)
        let names = tonightFrame.visibleConstellations(6)
        ok("今夜可见星座为秋季南天",
           names.contains("宝瓶座") || names.contains("摩羯座"))
        let decNight = Astronomy.frame(date: utc(2026, 12, 21, 14), place: .fallback)
        ok("冬至夜可见猎户座", decNight.visibleConstellations(6).contains("猎户座"))
        ok("满月夜暗星被月光压掉",
           decNight.projectedStars(size: size).count < starCount / 3)
        let twilight = Astronomy.frame(date: utc(2026, 11, 6, 9, 30), place: .fallback)
        ok("暮光时几乎看不到星", twilight.projectedStars(size: size).count < 12)
        ok("低空大气消光远强于天顶",
           Astronomy.airmass(altDeg: 5) > Astronomy.airmass(altDeg: 80) * 5)
        ok("演示天气标记为模拟", Demo.night.weather().simulated)

        print("— 关键时刻实时计算（本地星历，不依赖联网）")
        let sh = Place(name: "上海", region: "", latitude: 31.2304, longitude: 121.4737)
        let ev7 = Astronomy.dayEvents(date: utc(2026, 11, 7, 4), place: sh)  // 12:00 上海
        let hhmm = { (d: Date) -> String in
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            f.timeZone = TimeZone(secondsFromGMT: 28800)!; return f.string(from: d)
        }
        ok("上海 11-07 日出在 06:1x", hhmm(ev7.sunrise).hasPrefix("06:1"))
        ok("上海 11-07 日落在 16:5x/17:0x",
           hhmm(ev7.sunset).hasPrefix("16:5") || hhmm(ev7.sunset).hasPrefix("17:0"))
        ok("正午为白天", ev7.isDay)
        ok("下一次日落即当天日落", abs(ev7.nextSunset.timeIntervalSince(ev7.sunset)) < 1)
        // 关键时刻相位切换：日出前夜 → 日出后白天 → 日落后夜
        ok("日出前为夜", Astronomy.skyState(date: ev7.sunrise.addingTimeInterval(-600), place: sh).phase == .night)
        ok("日出后太阳已升起（白天或日出相位）", Astronomy.skyState(date: ev7.sunrise.addingTimeInterval(1800), place: sh).isSun)
        ok("日出 1.5 小时后为白天", Astronomy.skyState(date: ev7.sunrise.addingTimeInterval(5400), place: sh).phase == .day)
        ok("日出时刻为 dawn", Astronomy.skyState(date: ev7.sunrise.addingTimeInterval(300), place: sh).phase == .dawn)
        ok("日落前为 dusk", Astronomy.skyState(date: ev7.sunset.addingTimeInterval(-600), place: sh).phase == .dusk)
        ok("日落后为夜", Astronomy.skyState(date: ev7.sunset.addingTimeInterval(1800), place: sh).phase == .night)
        // 月升月落也能算出来
        ok("月升月落非空", ev7.moonrise != nil && ev7.moonset != nil)

        print("— 联网冒烟测试")
        let sem = DispatchSemaphore(value: 0)
        var live = false
        var liveTemp = Double.nan
        URLSession.shared.dataTask(with: WeatherService.forecastURL(for: .fallback)) { data, _, _ in
            if let data,
               let j = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let w = WeatherService.parse(json: j, place: .fallback) {
                live = w.sunrise < w.sunset && w.temperature > -100 && w.temperature < 100
                liveTemp = w.temperature
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 15)
        ok("Open-Meteo 实时数据可解析（\(String(format: "%.1f", liveTemp))°C）", live)

        print("——————————————")
        print("通过 \(passed) 项，失败 \(failed) 项")
        exit(failed == 0 ? 0 : 1)
    }
}
