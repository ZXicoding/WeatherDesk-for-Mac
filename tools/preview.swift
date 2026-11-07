import AppKit
import CoreGraphics
import Foundation
import QuartzCore

// 离屏渲染一组天气画面，拼成对比图用于人工校对渲染效果。
// 由 ./build.sh --preview 编译（本文件会作为 main.swift 参与编译，因为含顶层语句）。

enum Phase { case day, dawn, dusk, night }

struct Scene {
    let title: String
    let condition: Condition
    let code: Int
    let phase: Phase
    let temp: Double
    let wind: Double
    let windDir: Double
    let cloud: Int
    let humidity: Int
    var labels: Bool = false
}

let dateLabel: String = {
    let f = DateFormatter()
    f.dateFormat = "M月d日"
    f.timeZone = TimeZone(secondsFromGMT: 8 * 3600)
    f.locale = Locale(identifier: "zh_CN")
    return f.string(from: Date())
}()

let scenes: [Scene] = [
    Scene(title: "晴 · 正午", condition: .clear, code: 0, phase: .day,
          temp: 24, wind: 9, windDir: 80, cloud: 4, humidity: 42),
    Scene(title: "少云 · 傍晚", condition: .partlyCloudy, code: 2, phase: .dusk,
          temp: 19, wind: 14, windDir: 250, cloud: 34, humidity: 55),
    Scene(title: "晴 · \(dateLabel) 22:00 上海真实星空", condition: .clear, code: 0, phase: .night,
          temp: 8, wind: 5, windDir: 30, cloud: 2, humidity: 61),
    Scene(title: "同一片夜空 · 星座连线与亮星名", condition: .clear, code: 0, phase: .night,
          temp: 8, wind: 5, windDir: 30, cloud: 2, humidity: 61, labels: true),
    Scene(title: "阴 · 多云", condition: .cloudy, code: 3, phase: .day,
          temp: 17, wind: 18, windDir: 210, cloud: 72, humidity: 70),
    Scene(title: "下雨", condition: .rain, code: 63, phase: .day,
          temp: 13, wind: 22, windDir: 240, cloud: 88, humidity: 92),
    Scene(title: "雷阵雨", condition: .thunder, code: 95, phase: .day,
          temp: 16, wind: 31, windDir: 265, cloud: 96, humidity: 95),
    Scene(title: "下雪", condition: .snow, code: 73, phase: .day,
          temp: -2, wind: 8, windDir: 20, cloud: 84, humidity: 88),
    Scene(title: "雾", condition: .fog, code: 45, phase: .day,
          temp: 6, wind: 3, windDir: 100, cloud: 90, humidity: 98),
]

func makeWeather(_ s: Scene) -> Weather {
    let now = Date()
    let sunrise: Date, sunset: Date, nextSunrise: Date
    switch s.phase {
    case .day:
        sunrise = now.addingTimeInterval(-5 * 3600)
        sunset = now.addingTimeInterval(5 * 3600)
        nextSunrise = sunrise.addingTimeInterval(86400)
    case .dawn:
        sunrise = now.addingTimeInterval(-12 * 60)
        sunset = now.addingTimeInterval(10 * 3600)
        nextSunrise = sunrise.addingTimeInterval(86400)
    case .dusk:
        sunrise = now.addingTimeInterval(-9 * 3600)
        sunset = now.addingTimeInterval(24 * 60)
        nextSunrise = sunrise.addingTimeInterval(86400)
    case .night:
        sunset = now.addingTimeInterval(-3 * 3600)
        sunrise = sunset.addingTimeInterval(-12 * 3600)
        nextSunrise = now.addingTimeInterval(5 * 3600)
    }
    return Weather(place: .fallback, condition: s.condition, code: s.code,
                   temperature: s.temp, apparent: s.temp - 1,
                   humidity: s.humidity, windSpeed: s.wind, windDirection: s.windDir,
                   precipitation: s.condition.isRainy ? 3.2 : 0,
                   cloudCover: s.cloud, isDay: s.phase == .day || s.phase == .dawn,
                   sunrise: sunrise, sunset: sunset, nextSunrise: nextSunrise,
                   observedAt: now, fetchedAt: now,
                   timeZoneName: "Asia/Shanghai", utcOffset: 8 * 3600,
                   simulated: true)
}

// MARK: - 窗口与截图

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let cellW: CGFloat = 720, cellH: CGFloat = 450
let win = NSWindow(contentRect: NSRect(x: 60, y: 80, width: cellW, height: cellH),
                   styleMask: [.borderless], backing: .buffered, defer: false)
win.isOpaque = false
win.backgroundColor = .clear
win.hasShadow = false
win.level = .floating
win.isReleasedWhenClosed = false
win.orderFrontRegardless()

func capture(_ windowNumber: Int) -> CGImage? {
    CGWindowListCreateImage(.null, [.optionIncludingWindow],
                            CGWindowID(windowNumber),
                            [.boundsIgnoreFraming, .bestResolution])
}

let outPath = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "/tmp/weatherdesk-preview.png"

var results: [(String, CGImage)] = []
for scene in scenes {
    let view = SkyView(frame: NSRect(x: 0, y: 0, width: cellW, height: cellH))
    view.hidesInfoForPreview = true
    view.forceStarLabels = scene.labels     // 夜空格展示真实月相；星图按当天 22:00 计算
    win.contentView = view
    view.apply(weather: makeWeather(scene), animated: false)
    if scene.condition == .thunder { view.previewStrike() }
    // 命令行工具没有 NSApp.run()，CAAnimation 不会推进：按各自动画的
    // timeOffset 把这一帧定格成静态 model 值，再抓窗口。
    view.bakeForStillPreview()
    Thread.sleep(forTimeInterval: 0.30)

    var img = capture(win.windowNumber)
    if img == nil || img!.width < 10 {
        img = view.previewSnapshot(scale: 1)      // 退路：直接渲染 layer 树
    }
    guard let image = img else {
        print("✗ \(scene.title)：截图失败")
        continue
    }
    results.append((scene.title, image))
    print("✓ \(scene.title)  \(image.width)×\(image.height)")
}
win.orderOut(nil)

// MARK: - 拼成一张对比图

let cols = 3
let rows = (results.count + cols - 1) / cols
let pad: CGFloat = 18
let labelH: CGFloat = 46
let totalW = Int(CGFloat(cols) * cellW + CGFloat(cols + 1) * pad)
let totalH = Int(CGFloat(rows) * (cellH + labelH) + CGFloat(rows + 1) * pad)
let ctx = CGContext(data: nil, width: totalW, height: totalH,
                    bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(NSColor(calibratedWhite: 0.09, alpha: 1).cgColor)
ctx.fill(CGRect(x: 0, y: 0, width: totalW, height: totalH))

let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = gctx
for (i, item) in results.enumerated() {
    let col = i % cols, row = i / cols
    let x = pad + CGFloat(col) * (cellW + pad)
    let y = CGFloat(totalH) - pad - CGFloat(row + 1) * (cellH + labelH) - CGFloat(row) * pad
    let rect = CGRect(x: x, y: y + labelH, width: cellW, height: cellH)
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 12, cornerHeight: 12, transform: nil))
    ctx.clip()
    let iw = CGFloat(item.1.width), ih = CGFloat(item.1.height)
    let s = max(cellW / iw, cellH / ih)
    let dw = iw * s, dh = ih * s
    ctx.draw(item.1, in: CGRect(x: rect.midX - dw / 2, y: rect.midY - dh / 2,
                                width: dw, height: dh))
    ctx.restoreGState()
    (item.0 as NSString).draw(at: NSPoint(x: x + 6, y: y + 10),
                              withAttributes: [.font: NSFont.boldSystemFont(ofSize: 20),
                                               .foregroundColor: NSColor.white])
}
NSGraphicsContext.restoreGraphicsState()

guard let final = ctx.makeImage(),
      let data = NSBitmapImageRep(cgImage: final).representation(using: .png, properties: [:]) else {
    print("✗ 拼图失败"); exit(1)
}
try data.write(to: URL(fileURLWithPath: outPath))
print("✓ 预览图：\(outPath)")
