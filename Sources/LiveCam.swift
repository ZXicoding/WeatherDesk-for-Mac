import Foundation
import AppKit
import CoreGraphics

extension Notification.Name {
    /// 抓到新的一帧（或需要回退静态底图）时发出；SkyView 只换底图，不重建粒子层
    static let wdLiveCamFrame = Notification.Name("com.xi.weatherdesk.liveCamFrame")
}

/// 公开摄像头的实时帧供给。
///
/// 这些站点（opencam.live 聚合的道路 / 气象 / 景区公开摄像头）提供的是每十几秒
/// 刷新一次的 JPEG 实时帧，而不是需要长期解码的视频流。桌面背景用「定时换一帧」
/// 更合适：CPU 几乎为零、复用现有底图图层、断网时能无缝回退到静态照片。
///
/// 选点策略：按 IP 定位到的坐标，在内置索引里挑大圆距离最近的若干摄像头；
/// 取帧失败自动跳到下一个候选，全部失败就清空帧让 SkyView 回退静态底图，
/// 60 秒后重试。最近一帧落盘，开机 / 断网时先用旧帧，避免桌面空白。
final class LiveCamFeed {
    static let shared = LiveCamFeed()

    /// 最近一帧实时画面。只在主线程读写。
    private(set) var currentFrame: CGImage?
    /// 当前生效的摄像头
    private(set) var camera: LiveCamera?
    /// 菜单里显示的一行状态
    private(set) var status: String = "未启用"
    private(set) var lastUpdated: Date?

    private var place: Place?
    private var pinnedID: String?
    private var queue: [LiveCamera] = []
    private var cursor = 0
    private var failures = 0
    private var retryScheduled = false
    private var timer: Timer?
    private var task: URLSessionDataTask?
    private var fetching = false
    /// 换地点 / 换摄像头时自增，让在途的旧请求结果作废
    private var generation = 0

    private lazy var session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 12
        c.timeoutIntervalForResource = 20
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpAdditionalHeaders = ["User-Agent": "WeatherDesk/1.4 (public webcam frame)"]
        return URLSession(configuration: c)
    }()

    private lazy var cacheURL: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("天气桌面/livecam", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last.jpg")
    }()

    private lazy var cacheMetaURL: URL =
        cacheURL.deletingLastPathComponent().appendingPathComponent("last.id")

    private init() {}

    // MARK: 对外接口（主线程调用）

    /// SkyView.apply 每次都会调；内部只在「地点变化 / 尚未启动」时真正启动，
    /// 所以 20 秒一次的太阳位置刷新不会重启抓帧定时器。
    func ensure(place p: Place) {
        guard Settings.shared.liveCamEnabled else { return }
        if place == p, timer != nil { return }
        place = p
        rebuildQueue()
        startTimer()
        fetch()
    }

    /// 换 IP / 换城市：立刻换摄像头，避免旧地点的画面串到新地点
    func update(place p: Place) {
        guard p != place else { return }
        place = p
        invalidateRequests()
        currentFrame = nil
        rebuildQueue()
        notify()                       // 先让桌面回退静态图
        fetch()
        startTimer()
    }

    func setEnabled(_ on: Bool) {
        if on {
            invalidateRequests()
            place = nil
            let p = Settings.shared.lastPlace ?? Place.fallback
            ensure(place: p)
        } else {
            invalidateRequests()
            timer?.invalidate()
            timer = nil
            status = "未启用"
            notify()                   // SkyView 重新选静态底图
        }
    }

    /// nil 表示回到「自动选最近」
    func pin(_ id: String?) {
        pinnedID = id
        invalidateRequests()
        currentFrame = nil
        rebuildQueue()
        notify()
        fetch()
        startTimer()
    }

    func setInterval(_ seconds: Int) {
        guard Settings.shared.liveCamEnabled else { return }
        startTimer()
        fetch()
    }

    func refreshNow() {
        guard Settings.shared.liveCamEnabled else { return }
        if queue.isEmpty { rebuildQueue() }
        cursor = 0
        failures = 0
        fetch()
    }

    /// 菜单里显示的候选（按距离排序）
    func nearby(_ limit: Int = 8) -> [LiveCamera] {
        LiveCamCatalog.candidates(for: lastWeatherPlace ?? place ?? Settings.shared.lastPlace ?? .fallback,
                                  limit: limit)
    }

    private var lastWeatherPlace: Place? { place }

    // MARK: 内部

    private func invalidateRequests() {
        generation += 1
        task?.cancel()
        task = nil
        fetching = false
        retryScheduled = false
    }

    private func rebuildQueue() {
        let p = place ?? Settings.shared.lastPlace ?? Place.fallback
        let fixed = Settings.forcedLiveCam ?? pinnedID
        if let id = fixed, let pinned = LiveCamCatalog.byID(id) {
            queue = [pinned] + LiveCamCatalog.candidates(for: p, limit: 6).filter { $0.id != id }
        } else {
            queue = LiveCamCatalog.candidates(for: p, limit: 8)
        }
        cursor = 0
        failures = 0
        camera = queue.first
        loadCachedFrame(matching: camera?.id)
    }

    /// 开机首帧用上次的缓存，但**必须和当前选中的摄像头一致**：
    /// 否则换 IP / 手动固定别的机位时，会先闪一下上一个地点的画面。
    private func loadCachedFrame(matching id: String?) {
        guard let id,
              let saved = try? String(contentsOf: cacheMetaURL, encoding: .utf8),
              saved.trimmingCharacters(in: .whitespacesAndNewlines) == id,
              let d = try? Data(contentsOf: cacheURL),
              let img = Self.decode(d) else {
            currentFrame = nil
            lastUpdated = nil
            return
        }
        currentFrame = img
        lastUpdated = (try? FileManager.default.attributesOfItem(atPath: cacheURL.path)[.modificationDate]) as? Date
        status = "\(camera?.display ?? id) · 上次的实时帧"
    }

    private func startTimer() {
        timer?.invalidate()
        let interval = Double(min(600, max(10, Settings.shared.liveCamInterval)))
        let t = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetch()
        }
        t.tolerance = min(3, interval * 0.2)
        timer = t
    }

    private func fetch() {
        guard Settings.shared.liveCamEnabled, !fetching else { return }
        if queue.isEmpty { rebuildQueue() }
        guard cursor < queue.count else { exhausted(); return }

        let cam = queue[cursor]
        guard let url = cam.frameURL else {
            cursor += 1
            fetch()
            return
        }
        fetching = true
        let gen = generation
        task = session.dataTask(with: url) { [weak self] data, response, _ in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // 解码放在后台队列，主线程只做赋值与通知
            let img: CGImage? = code == 200 ? data.flatMap(Self.decode) : nil
            DispatchQueue.main.async {
                guard let self, gen == self.generation else { return }
                self.fetching = false
                if let img {
                    self.accept(img, cam: cam, data: data)
                } else {
                    self.fail()
                }
            }
        }
        task?.resume()
    }

    private func accept(_ img: CGImage, cam: LiveCamera, data: Data?) {
        failures = 0
        retryScheduled = false
        camera = cam
        currentFrame = img
        lastUpdated = Date()
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"
        status = "\(cam.display) · \(f.string(from: Date())) 实时帧"
        if let d = data {
            try? d.write(to: cacheURL, options: .atomic)
            try? cam.id.write(to: cacheMetaURL, atomically: true, encoding: .utf8)
        }
        notify()
    }

    private func fail() {
        failures += 1
        if failures >= 2 { failures = 0; cursor += 1 }
        status = "取帧失败，正在尝试附近其他摄像头"
        if currentFrame == nil { notify() }
        guard cursor < queue.count else { exhausted(); return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.fetch() }
    }

    /// 附近候选全部不可用：清空实时帧让 SkyView 回退静态照片，60 秒后重试
    private func exhausted() {
        status = "附近摄像头暂不可用 · 已回退静态背景"
        currentFrame = nil
        notify()
        guard !retryScheduled else { return }
        retryScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, Settings.shared.liveCamEnabled else { return }
            self.retryScheduled = false
            self.rebuildQueue()
            self.fetch()
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: .wdLiveCamFrame, object: nil)
    }

    /// JPEG → CGImage。尺寸下限用来挡住错误页 / 占位图 / 空白帧。
    private static func decode(_ data: Data) -> CGImage? {
        guard data.count > 4096,
              let rep = NSBitmapImageRep(data: data),
              rep.pixelsWide >= 320, rep.pixelsHigh >= 180 else { return nil }
        return rep.cgImage
    }
}
