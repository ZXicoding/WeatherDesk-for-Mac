import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var bar: MenuBarController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 调试 / 预览用： open "天气桌面.app" --args --demo=rain
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--demo=") }) {
            WeatherService.shared.demo = Demo(rawValue: String(arg.dropFirst("--demo=".count)))
        }

        RainAudio.shared.configure()
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
