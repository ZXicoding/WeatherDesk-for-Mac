import AppKit
import CoreGraphics

/// 在每一块屏幕的「桌面壁纸层」放一块透明窗口。
/// 窗口不接收鼠标、不进 Dock、不参与窗口切换，桌面图标仍在水印之上。
final class DesktopController {
    static let shared = DesktopController()

    private var entries: [(window: NSWindow, view: SkyView)] = []
    private var lastWeather: Weather?
    private var sunTimer: Timer?
    private var levelOffset = 1

    func start() {
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--level=") }),
           let n = Int(String(arg.dropFirst("--level=".count))) {
            levelOffset = n
        }
        rebuild()
        NotificationCenter.default.addObserver(
            self, selector: #selector(screenParamsChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(settingsChanged),
            name: .wdSettingsChanged, object: nil)

        // 两次天气刷新之间，太阳/月亮也持续移动，日落过渡是连续的
        sunTimer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in
            guard let w = self?.lastWeather else { return }
            self?.apply(w, animated: true)
        }
        sunTimer?.tolerance = 5
    }

    @objc private func screenParamsChanged() { rebuild() }

    @objc private func settingsChanged() {
        rebuild()
    }

    func reapply() {
        if let w = lastWeather { apply(w, animated: false) }
    }

    // MARK: 窗口管理

    func rebuild() {
        for e in entries {
            e.window.orderOut(nil)
            e.window.close()
        }
        entries.removeAll()
        guard Settings.shared.enabled else { return }

        let base = Int(CGWindowLevelForKey(.desktopWindow))
        let level = NSWindow.Level(rawValue: base + levelOffset)

        for screen in NSScreen.screens {
            let win = NSWindow(contentRect: screen.frame,
                               styleMask: [.borderless],
                               backing: .buffered,
                               defer: false)
            win.level = level
            win.isOpaque = false
            win.backgroundColor = .clear
            win.hasShadow = false
            win.ignoresMouseEvents = true
            win.isMovable = false
            win.canHide = false
            win.hidesOnDeactivate = false
            win.isReleasedWhenClosed = false
            win.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
            // 不能设 sharingType = .none：WindowServer 会把这类窗口从屏幕合成里剔除，
            // 桌面层会变成一块黑洞（截图也抓不到）。保持默认可读共享。

            let view = SkyView(frame: NSRect(origin: .zero, size: screen.frame.size))
            win.contentView = view
            win.setFrame(screen.frame, display: true)
            win.orderFrontRegardless()
            entries.append((win, view))
        }

        if let w = lastWeather { apply(w, animated: false) }
    }

    // MARK: 数据

    func consume(_ result: Result<Weather, Error>) {
        switch result {
        case .success(let w):
            lastWeather = w
            apply(w, animated: true)
        case .failure:
            // 断网时保持上一帧画面，不清空桌面
            break
        }
    }

    private func apply(_ w: Weather, animated: Bool) {
        guard Settings.shared.enabled else { return }
        guard !entries.isEmpty else { return }
        for e in entries { e.view.apply(weather: w, animated: animated) }
    }
}
