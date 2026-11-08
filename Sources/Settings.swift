import Foundation
import AppKit

extension Notification.Name {
    static let wdSettingsChanged = Notification.Name("com.xi.weatherdesk.settingsChanged")
}

enum LocationMode: String {
    case autoIP
    case precise
    case manual

    var label: String {
        switch self {
        case .autoIP:  return "自动定位（IP）"
        case .precise: return "精确定位（系统）"
        case .manual:  return "手动指定城市"
        }
    }
}

struct Place: Codable, Equatable {
    var name: String
    var region: String
    var latitude: Double
    var longitude: Double

    static let fallback = Place(name: "上海", region: "中国", latitude: 31.2304, longitude: 121.4737)

    var display: String {
        if region.isEmpty || region == name { return name }
        return "\(name) · \(region)"
    }
}

/// 所有偏好都落在 UserDefaults，不写配置文件、不联网上传。
final class Settings {
    static let shared = Settings()
    private let ud = UserDefaults.standard
    private let p = "weatherdesk."

    private init() {}

    private func read<T>(_ key: String, _ fallback: T) -> T {
        (ud.object(forKey: p + key) as? T) ?? fallback
    }

    private func write<T>(_ key: String, _ value: T) {
        ud.set(value, forKey: p + key)
        NotificationCenter.default.post(name: .wdSettingsChanged, object: nil)
    }

    /// 桌面天气总开关
    var enabled: Bool {
        get { read("enabled", true) }
        set { write("enabled", newValue) }
    }

    /// 右下角天气角标
    var showInfo: Bool {
        get { read("showInfo", true) }
        set { write("showInfo", newValue) }
    }

    /// 星图标注：星座连线、亮星与行星中文名。默认关闭——真实天空里没有线
    var showConstellations: Bool {
        get { read("showConstellations", false) }
        set { write("showConstellations", newValue) }
    }

    /// 粒子密度倍率 0.3 ... 1.6
    var intensity: Double {
        get { read("intensity", 1.0) }
        set { write("intensity", min(1.6, max(0.3, newValue))) }
    }

    /// 天空不透明度 0 ... 1，越小越能透出原来的壁纸
    var skyOpacity: Double {
        get { read("skyOpacity", 0.94) }
        set { write("skyOpacity", min(1.0, max(0.0, newValue))) }
    }

    /// 实景模式：用真实照片做底图，云/雨雪/闪电以半透明动画层叠加在上面。
    /// 找不到照片素材时自动回退到程序化天空。
    var realSceneEnabled: Bool {
        get { read("realSceneEnabled", true) }
        set { write("realSceneEnabled", newValue) }
    }

    var refreshMinutes: Int {
        get { read("refreshMinutes", 10) }
        set { write("refreshMinutes", min(60, max(2, newValue))) }
    }

    var locationMode: LocationMode {
        get { LocationMode(rawValue: read("locationMode", "autoIP")) ?? .autoIP }
        set { write("locationMode", newValue.rawValue) }
    }

    var manualPlace: Place? {
        get {
            guard let d = ud.data(forKey: p + "manualPlace") else { return nil }
            return try? JSONDecoder().decode(Place.self, from: d)
        }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                ud.set(d, forKey: p + "manualPlace")
            } else {
                ud.removeObject(forKey: p + "manualPlace")
            }
            NotificationCenter.default.post(name: .wdSettingsChanged, object: nil)
        }
    }

    /// 断网时继续用上一次成功的定位
    var lastPlace: Place? {
        get {
            guard let d = ud.data(forKey: p + "lastPlace") else { return nil }
            return try? JSONDecoder().decode(Place.self, from: d)
        }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                ud.set(d, forKey: p + "lastPlace")
            }
        }
    }

    /// 最近一次成功获取的天气。开机时网络还没就绪，先用它在 0 秒内把桌面画出来，
    /// 避免登录项抢跑造成「窗口建好了但一片黑」。只存本机 UserDefaults。
    /// 注意：这里刻意不 post .wdSettingsChanged，否则每次刷新都会触发重建桌面窗口。
    var cachedWeather: Weather? {
        get {
            guard let d = ud.data(forKey: p + "cachedWeather") else { return nil }
            return try? JSONDecoder().decode(Weather.self, from: d)
        }
        set {
            if let v = newValue, let d = try? JSONEncoder().encode(v) {
                ud.set(d, forKey: p + "cachedWeather")
            } else {
                ud.removeObject(forKey: p + "cachedWeather")
            }
        }
    }

    var launchAtLogin: Bool {
        get { read("launchAtLogin", false) }
        set { write("launchAtLogin", newValue) }
    }
}
