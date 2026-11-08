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
