import Foundation
import AppKit

extension Notification.Name {
    static let wdSettingsChanged = Notification.Name("com.xi.weatherdesk.settingsChanged")
}

/// 背景来源。v1.3 起默认「实景照片底图 + 粒子动画层」。
/// - photo：真实照片做底，云 / 雨 / 雪 / 雾 / 闪电作为动画层叠加
/// - eco  ：按经纬度现场绘制当地自然生态（实验，分层绘制而非照片）
/// - sky  ：不使用底图，纯程序化天空 / 日月 / 星图
enum BackgroundMode: String {
    case photo
    case eco
    case sky
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

    /// 仅由启动参数 --biome=<pack> 设置，用于预览 / 自检，不写入偏好
    static var forcedBiomePack: String?
    /// 仅由启动参数 --cam=<id> 设置，用于预览某个公开摄像头，不写入偏好
    static var forcedLiveCam: String?
    /// 仅由 --live / --no-live 设置，用于截屏自检，不写入偏好
    static var debugLiveCam: Bool?
    private let ud = UserDefaults.standard
    private let p = "weatherdesk."

    private init() {
        // v1.2 曾把「当地生态」设为默认并写入偏好。v1.3 回到照片实景，
        // 这里做一次性迁移，避免升级后旧偏好把画面又切回插画风。
        let migratedKey = p + "bgDefaultV13"
        if ud.object(forKey: migratedKey) == nil {
            ud.set(BackgroundMode.photo.rawValue, forKey: p + "backgroundMode")
            ud.set(true, forKey: migratedKey)
        }
    }

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

    /// 背景来源：默认是实景照片底图 + 粒子动画层。切换时会重建桌面窗口与动画层。
    var backgroundMode: BackgroundMode {
        get { BackgroundMode(rawValue: read("backgroundMode", "photo")) ?? .photo }
        set { write("backgroundMode", newValue.rawValue) }
    }

    /// 实景底图按当地时间每 2 小时换一张（12 档）。关掉则回到旧的「天气 × 白天/暮色/夜」5 张。
    /// 默认开启：旧的 night 档覆盖日落到日出的十几个小时，下午和深夜会是同一张图。
    var twoHourScenes: Bool {
        get { read("twoHourScenes", true) }
        set { write("twoHourScenes", newValue) }
    }

    /// 换 IP / 换城市时，按经纬度与当地气候推断生态带，自动切到对应的一套实景照片。
    /// 默认关闭：内置目前只提供湿地一套，其余生态带可用 `Resources/biomes/<pack>/`
    /// 自行放入同名 5 张后开启；空包会自动回退到通用静态底图。
    var autoBiome: Bool {
        get { read("autoBiome", false) }
        set { write("autoBiome", newValue) }
    }

    // MARK: 公开实时摄像头

    /// 用附近公开摄像头的最新一帧 JPEG 做底图。
    /// 默认关闭：真实夜间机位常是暗场城市灯光且带站点水印，会盖掉已确认的静态底图；
    /// 在菜单栏「实时摄像头」里可一键开启，关掉即刻回到静态照片。
    var liveCamEnabled: Bool {
        get {
            if let debug = Settings.debugLiveCam { return debug }
            return read("liveCamEnabled", false)
        }
        set { write("liveCamEnabled", newValue) }
    }

    /// 抓帧间隔（秒）。opencam.live 的快照约 15 秒更新一次。
    var liveCamInterval: Int {
        get { read("liveCamInterval", 20) }
        set { write("liveCamInterval", min(600, max(10, newValue))) }
    }

    /// 手动固定的摄像头 ID；nil 时按定位坐标自动选最近的
    var liveCamID: String? {
        get {
            let v: String = read("liveCamID", "")
            return v.isEmpty ? nil : v
        }
        set { write("liveCamID", newValue ?? "") }
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
