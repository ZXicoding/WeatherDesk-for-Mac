import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var bar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 重装 / 换签名后 SMAppService 登录项可能失效；用户开启过就自动补注册，
        // 否则「下次开机」连进程都不会起来。
        if Settings.shared.launchAtLogin, SMAppService.mainApp.status != .enabled {
            do { try SMAppService.mainApp.register() }
            catch { NSLog("WeatherDesk: 重新注册登录项失败 \(error.localizedDescription)") }
        }

        // 调试 / 预览用： open "天气桌面.app" --args --demo=rain
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--demo=") }) {
            WeatherService.shared.demo = Demo(rawValue: String(arg.dropFirst("--demo=".count)))
        }
        // 预览 / 自检用：--biome=desert 强制指定生态带照片包，不写入偏好
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--biome=") }) {
            Settings.forcedBiomePack = String(arg.dropFirst("--biome=".count))
        }
        // 预览 / 自检用：--cam=<id> 固定某个公开摄像头，--live / --no-live 临时开关。
        // 全部只影响本次进程，不改用户偏好。
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--cam=") }) {
            Settings.forcedLiveCam = String(arg.dropFirst("--cam=".count))
            Settings.debugLiveCam = true
        }
        if CommandLine.arguments.contains("--live") { Settings.debugLiveCam = true }
        if CommandLine.arguments.contains("--no-live") { Settings.debugLiveCam = false }

        DesktopController.shared.start()

        let b = MenuBarController()
        b.start()
        bar = b

        WeatherService.shared.onUpdate = { [weak b] result in
            DesktopController.shared.consume(result)
            b?.update(result)
        }
        WeatherService.shared.start()
    }
}

let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.accessory)
app.run()
