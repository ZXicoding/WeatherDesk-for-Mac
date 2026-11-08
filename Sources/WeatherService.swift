import Foundation
import AppKit
import CoreLocation

enum WeatherError: LocalizedError {
    case offline
    case badData
    case noLocation

    var errorDescription: String? {
        switch self {
        case .offline: return "连不上天气服务，正在重试"
        case .badData: return "天气数据格式异常"
        case .noLocation: return "定位失败，已使用上次的位置"
        }
    }
}

/// 用于预览各种天气，不影响真实数据；只存在内存里，重启即回到实时模式。
enum Demo: String, CaseIterable {
    case clear, sunset, rain, storm, snow, fog, night

    var label: String {
        switch self {
        case .clear:  return "晴天"
        case .sunset: return "日落"
        case .rain:   return "下雨"
        case .storm:  return "雷暴"
        case .snow:   return "下雪"
        case .fog:    return "雾"
        case .night:  return "夜晚"
        }
    }

    func weather() -> Weather {
        let now = Date()
        var cond: Condition = .clear
        var temp = 23.0
        var wind = 8.0
        var humidity = 48
        var clouds = 8
        var precip = 0.0
        var code = 0
        var rise = now.addingTimeInterval(-4 * 3600)
        var set = now.addingTimeInterval(4 * 3600)
        var next = rise.addingTimeInterval(24 * 3600)

        switch self {
        case .clear:
            code = 0
        case .sunset:
            rise = now.addingTimeInterval(-9.2 * 3600)
            set = now.addingTimeInterval(9 * 60)
            next = rise.addingTimeInterval(24 * 3600)
            cond = .partlyCloudy; clouds = 26; temp = 19; wind = 6; humidity = 55; code = 2
        case .rain:
            cond = .rain; clouds = 88; temp = 14; wind = 22; humidity = 92; precip = 3.2; code = 63
        case .storm:
            cond = .thunder; clouds = 98; temp = 16; wind = 41; humidity = 95; precip = 12.5; code = 95
        case .snow:
            cond = .snow; clouds = 82; temp = -3; wind = 9; humidity = 86; precip = 1.8; code = 73
        case .fog:
            cond = .fog; clouds = 95; temp = 9; wind = 2; humidity = 99; code = 45
        case .night:
            set = now.addingTimeInterval(-2 * 3600)
            rise = set.addingTimeInterval(-10 * 3600)
            next = set.addingTimeInterval(10 * 3600)
            cond = .clear; clouds = 4; temp = 11; wind = 4; humidity = 60; code = 0
        }

        // 演示的星空仍按用户真实所在地计算，否则会变成赤道上的星图
        let base = Settings.shared.lastPlace ?? Settings.shared.manualPlace ?? .fallback
        return Weather(
            place: Place(name: "演示 · \(label)", region: base.name,
                         latitude: base.latitude, longitude: base.longitude),
            condition: cond, code: code,
            temperature: temp, apparent: temp - 1.5, humidity: humidity,
            windSpeed: wind, windDirection: 210,
            precipitation: precip, cloudCover: clouds,
            isDay: self != .night,
            sunrise: rise, sunset: set, nextSunrise: next,
            observedAt: now, fetchedAt: now,
            timeZoneName: TimeZone.current.identifier,
            utcOffset: TimeZone.current.secondsFromGMT(),
            simulated: true)
    }
}

final class WeatherService: NSObject {
    static let shared = WeatherService()

    /// 结果总在主线程回调
    var onUpdate: ((Result<Weather, Error>) -> Void)?
    var demo: Demo?

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c)
    }()
    private var timer: Timer?
    private var busy = false
    private var wakeObserver: NSObjectProtocol?
    /// 请求链的代次：watchdog 判死一次请求后，让迟到的回调自动作废
    private var generation: UInt64 = 0
    private var watchdogWork: DispatchWorkItem?
    private var retryWork: DispatchWorkItem?
    private var retryDelay: TimeInterval = 5
    /// 调试用：模拟开机时网络完全不通（不发任何请求）
    private var simulateOffline = false

    func start() {
        scheduleTimer()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                self?.refresh()
            }
        NotificationCenter.default.addObserver(
            self, selector: #selector(scheduleTimer),
            name: .wdSettingsChanged, object: nil)
        simulateOffline = CommandLine.arguments.contains("--simulate-offline")

        // ① 开机首帧：不等网络，立刻用上次成功的天气把桌面画出来。
        //   登录项抢跑时 Wi-Fi / DNS 常常还没就绪，这是杜绝「黑洞桌面」的关键。
        DispatchQueue.main.async { [weak self] in
            self?.onUpdate?(.success(Self.offlineWeather()))
        }

        // ② 等 WindowServer 与网络栈稳定后再发第一次请求
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            self?.refresh()
        }
    }

    /// 无需网络的首帧：优先用缓存的真实天气；全新安装则按本地天文时刻生成一个合理天空。
    static func offlineWeather() -> Weather {
        if let cached = Settings.shared.cachedWeather { return cached }
        let place = Settings.shared.lastPlace ?? Settings.shared.manualPlace ?? .fallback
        let ev = Astronomy.dayEvents(place: place)
        let now = Date()
        return Weather(
            place: place,
            condition: ev.isDay ? .partlyCloudy : .clear,
            code: ev.isDay ? 2 : 0,
            temperature: 18, apparent: 17, humidity: 55,
            windSpeed: 6, windDirection: 210,
            precipitation: 0, cloudCover: 25,
            isDay: ev.isDay,
            sunrise: ev.sunrise, sunset: ev.sunset, nextSunrise: ev.nextSunrise,
            observedAt: now, fetchedAt: now,
            timeZoneName: TimeZone.current.identifier,
            utcOffset: TimeZone.current.secondsFromGMT())
    }

    @objc func scheduleTimer() {
        timer?.invalidate()
        let interval = TimeInterval(Settings.shared.refreshMinutes * 60)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        timer?.tolerance = 30
    }

    func refresh() {
        retryWork?.cancel()
        guard !busy else { return }
        if let d = demo {
            let w = d.weather()
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(.success(w)) }
            return
        }
        if simulateOffline {
            DispatchQueue.main.async { [weak self] in self?.onUpdate?(.failure(WeatherError.offline)) }
            scheduleRetry()
            return
        }

        busy = true
        generation &+= 1
        let gen = generation
        armWatchdog(gen)

        resolvePlace { [weak self] place in
            guard let self else { return }
            self.fetch(place: place) { result in
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }   // 丢弃已被 watchdog 判死的旧请求
                    self.busy = false
                    self.watchdogWork?.cancel()
                    switch result {
                    case .success(let w):
                        Settings.shared.cachedWeather = w          // 下次开机的首帧素材
                        self.retryDelay = 5
                        self.onUpdate?(.success(w))
                    case .failure(let e):
                        // 断网时保留上一帧画面，并快速重试，而不是干等 10 分钟
                        self.onUpdate?(.failure(e))
                        self.scheduleRetry()
                    }
                }
            }
        }
    }

    /// 定位或请求链若没回调，busy 会永久卡住后续所有刷新 —— 15 秒强制解锁并重试。
    private func armWatchdog(_ gen: UInt64) {
        watchdogWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, gen == self.generation, self.busy else { return }
            self.generation &+= 1        // 让迟到的回调作废
            self.busy = false
            self.onUpdate?(.failure(WeatherError.offline))
            self.scheduleRetry()
        }
        watchdogWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
    }

    /// 失败后 5→10→20→40→60 秒指数退避，网络一恢复立刻回到实时数据。
    private func scheduleRetry() {
        retryWork?.cancel()
        let delay = retryDelay
        retryDelay = min(60, retryDelay * 2)
        let work = DispatchWorkItem { [weak self] in self?.refresh() }
        retryWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    // MARK: 定位

    private func resolvePlace(_ done: @escaping (Place) -> Void) {
        let s = Settings.shared
        switch s.locationMode {
        case .manual:
            done(s.manualPlace ?? s.lastPlace ?? .fallback)
        case .precise:
            LocationService.shared.locate { place in
                if let place { s.lastPlace = place; done(place) }
                else { done(s.lastPlace ?? .fallback) }
            }
        case .autoIP:
            ipPlace { place in
                if let place { s.lastPlace = place; done(place) }
                else { done(s.lastPlace ?? .fallback) }
            }
        }
    }

    private func ipPlace(_ done: @escaping (Place?) -> Void) {
        getJSON(URL(string: "https://ipwho.is/")!) { [weak self] j in
            if let j, ((j["success"] as? Bool) ?? false),
               let lat = j["latitude"] as? Double, let lon = j["longitude"] as? Double {
                let city = (j["city"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "当前位置"
                let region = (j["region"] as? String).flatMap { $0.isEmpty ? nil : $0 }
                    ?? (j["country"] as? String) ?? ""
                done(Place(name: city, region: region, latitude: lat, longitude: lon))
                return
            }
            // 备用定位源
            self?.getJSON(URL(string: "https://ipinfo.io/json")!) { j2 in
                guard let j2, let loc = j2["loc"] as? String else { done(nil); return }
                let parts = loc.split(separator: ",").map(String.init)
                guard parts.count == 2, let lat = Double(parts[0]), let lon = Double(parts[1]) else { done(nil); return }
                let city = (j2["city"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "当前位置"
                let region = (j2["region"] as? String) ?? (j2["country"] as? String) ?? ""
                done(Place(name: city, region: region, latitude: lat, longitude: lon))
            }
        }
    }

    /// 城市名检索，给「手动指定城市」用
    func searchCity(_ query: String, completion: @escaping ([Place]) -> Void) {
        var c = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        c.queryItems = [
            URLQueryItem(name: "name", value: query),
            URLQueryItem(name: "count", value: "8"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json"),
        ]
        guard let url = c.url else { completion([]); return }
        getJSON(url) { j in
            guard let list = j?["results"] as? [[String: Any]] else { completion([]); return }
            let places: [Place] = list.compactMap { d in
                guard let name = d["name"] as? String,
                      let lat = d["latitude"] as? Double,
                      let lon = d["longitude"] as? Double else { return nil }
                let admin = (d["admin1"] as? String) ?? ""
                let country = (d["country"] as? String) ?? ""
                let region = admin == name ? country : (admin.isEmpty ? country : "\(admin) · \(country)")
                return Place(name: name, region: region, latitude: lat, longitude: lon)
            }
            DispatchQueue.main.async { completion(places) }
        }
    }

    // MARK: 天气请求

    static func forecastURL(for place: Place) -> URL {
        var c = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        c.queryItems = [
            URLQueryItem(name: "latitude", value: String(format: "%.4f", place.latitude)),
            URLQueryItem(name: "longitude", value: String(format: "%.4f", place.longitude)),
            URLQueryItem(name: "current", value:
                "temperature_2m,relative_humidity_2m,apparent_temperature,is_day," +
                "precipitation,rain,showers,snowfall,weather_code,cloud_cover," +
                "wind_speed_10m,wind_direction_10m"),
            URLQueryItem(name: "daily", value: "sunrise,sunset"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "3"),
        ]
        return c.url!
    }

    private func fetch(place: Place, done: @escaping (Result<Weather, Error>) -> Void) {
        let url = Self.forecastURL(for: place)
        getJSON(url) { j in
            guard let j else { done(.failure(WeatherError.offline)); return }
            guard let w = WeatherService.parse(json: j, place: place) else { done(.failure(WeatherError.badData)); return }
            done(.success(w))
        }
    }

    /// 纯函数，便于自检覆盖
    static func parse(json j: [String: Any], place: Place) -> Weather? {
        guard let cur = j["current"] as? [String: Any],
              let daily = j["daily"] as? [String: Any],
              let riseStrings = daily["sunrise"] as? [String], riseStrings.count >= 2,
              let setStrings = daily["sunset"] as? [String], setStrings.count >= 2,
              let offset = j["utc_offset_seconds"] as? Int
        else { return nil }

        let tz = TimeZone(secondsFromGMT: offset) ?? .current
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = tz
        f.locale = Locale(identifier: "en_US_POSIX")

        let rises = riseStrings.compactMap { f.date(from: $0) }
        let sets = setStrings.compactMap { f.date(from: $0) }
        guard rises.count >= 2, sets.count >= 2 else { return nil }

        let now = Date()
        let rise = rises.last(where: { $0 <= now }) ?? rises[0]
        let set = sets.first(where: { $0 > rise }) ?? sets[sets.count - 1]
        let nextRise = rises.first(where: { $0 > set }) ?? rise.addingTimeInterval(24 * 3600)

        func num(_ key: String, _ fallback: Double = 0) -> Double {
            if let v = cur[key] as? Double { return v }
            if let v = cur[key] as? Int { return Double(v) }
            return fallback
        }
        let code = Int(num("weather_code"))
        let observed = (cur["time"] as? String).flatMap(f.date(from:)) ?? now

        return Weather(
            place: place,
            condition: condition(for: code), code: code,
            temperature: num("temperature_2m"),
            apparent: num("apparent_temperature"),
            humidity: Int(num("relative_humidity_2m")),
            windSpeed: num("wind_speed_10m"),
            windDirection: num("wind_direction_10m"),
            precipitation: num("precipitation"),
            cloudCover: Int(num("cloud_cover")),
            isDay: Int(num("is_day")) == 1,
            sunrise: rise, sunset: set, nextSunrise: nextRise,
            observedAt: observed, fetchedAt: now,
            timeZoneName: (j["timezone"] as? String) ?? tz.identifier,
            utcOffset: offset)
    }

    // MARK: 底层请求

    private func getJSON(_ url: URL, completion: @escaping ([String: Any]?) -> Void) {
        var req = URLRequest(url: url)
        req.setValue("WeatherDesk/1.0 (macOS)", forHTTPHeaderField: "User-Agent")
        session.dataTask(with: req) { data, response, error in
            guard error == nil,
                  let code = (response as? HTTPURLResponse)?.statusCode,
                  (200..<300).contains(code),
                  let data,
                  let obj = try? JSONSerialization.jsonObject(with: data),
                  let dict = obj as? [String: Any]
            else { completion(nil); return }
            completion(dict)
        }.resume()
    }
}

// MARK: - 系统精确定位（仅在用户主动打开时调用）

final class LocationService: NSObject, CLLocationManagerDelegate {
    static let shared = LocationService()
    private let manager = CLLocationManager()
    private var completion: ((Place?) -> Void)?
    private var settled = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyThreeKilometers
    }

    func locate(_ done: @escaping (Place?) -> Void) {
        completion = done
        settled = false
        switch manager.authorizationStatus {
        case .notDetermined:
            manager.requestWhenInUseAuthorization()
            armTimeout()
        case .authorizedAlways:
            manager.startUpdatingLocation()
            armTimeout()
        default:
            finish(nil)
        }
    }

    private func armTimeout() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) { [weak self] in
            self?.finish(nil)
        }
    }

    private func finish(_ place: Place?) {
        guard !settled else { return }
        settled = true
        manager.stopUpdatingLocation()
        let cb = completion
        completion = nil
        cb?(place)
    }

    func locationManager(_ manager: CLLocationManager, didChangeAuthorization status: CLAuthorizationStatus) {
        if status == .authorizedAlways {
            manager.startUpdatingLocation()
        } else if status == .denied || status == .restricted {
            finish(nil)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last else { return }
        manager.stopUpdatingLocation()
        CLGeocoder().reverseGeocodeLocation(loc) { [weak self] marks, _ in
            let m = marks?.first
            let name = m?.locality ?? m?.administrativeArea ?? "当前位置"
            let region = m?.administrativeArea ?? m?.country ?? ""
            let place = Place(name: name, region: region,
                              latitude: loc.coordinate.latitude,
                              longitude: loc.coordinate.longitude)
            DispatchQueue.main.async { self?.finish(place) }
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        finish(nil)
    }
}
