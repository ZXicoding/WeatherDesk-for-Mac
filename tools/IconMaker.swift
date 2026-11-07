import AppKit

@main
struct IconMaker {
    static func main() {
        let out = CommandLine.arguments[1]
        try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)
        let specs: [(Int, String)] = [
            (16, "icon_16x16.png"),
            (32, "icon_16x16@2x.png"),
            (32, "icon_32x32.png"),
            (64, "icon_32x32@2x.png"),
            (128, "icon_128x128.png"),
            (256, "icon_128x128@2x.png"),
            (256, "icon_256x256.png"),
            (512, "icon_256x256@2x.png"),
            (512, "icon_512x512.png"),
            (1024, "icon_512x512@2x.png"),
        ]
        for (size, name) in specs {
            let img = icon(CGFloat(size))
            guard let tiff = img.tiffRepresentation,
                  let rep = NSBitmapImageRep(data: tiff),
                  let png = rep.representation(using: .png, properties: [:]) else { continue }
            try? png.write(to: URL(fileURLWithPath: out).appendingPathComponent(name))
        }
    }

    static func icon(_ s: CGFloat) -> NSImage {
        return NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let r = NSRect(x: 0, y: 0, width: s, height: s)
            let outer = NSBezierPath(roundedRect: r.insetBy(dx: s * 0.02, dy: s * 0.02),
                                     xRadius: s * 0.22, yRadius: s * 0.22)
            outer.addClip()

            let sky = NSGradient(colors: [
                NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.72, alpha: 1),
                NSColor(calibratedRed: 0.42, green: 0.69, blue: 0.88, alpha: 1),
                NSColor(calibratedRed: 0.93, green: 0.72, blue: 0.56, alpha: 1),
            ])
            sky?.draw(in: r, angle: -90)

            // 太阳
            NSColor(calibratedRed: 1.0, green: 0.88, blue: 0.52, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.58, y: s * 0.55, width: s * 0.28, height: s * 0.28)).fill()

            // 云：几段圆角矩形 + 圆
            let cloud = NSColor.white.withAlphaComponent(0.95)
            cloud.setFill()
            let base = NSRect(x: s * 0.14, y: s * 0.40, width: s * 0.62, height: s * 0.20)
            NSBezierPath(roundedRect: base, xRadius: s * 0.10, yRadius: s * 0.10).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.22, y: s * 0.47, width: s * 0.26, height: s * 0.26)).fill()
            NSBezierPath(ovalIn: NSRect(x: s * 0.42, y: s * 0.50, width: s * 0.30, height: s * 0.30)).fill()

            // 雨滴：略微倾斜的细长条
            NSColor.white.withAlphaComponent(0.92).setFill()
            for i in 0..<5 {
                let x = s * (0.21 + CGFloat(i) * 0.115)
                let y = s * 0.20
                let w = s * 0.032, h = s * 0.14, slant = s * 0.035
                let p = NSBezierPath()
                p.move(to: NSPoint(x: x + slant, y: y + h))
                p.line(to: NSPoint(x: x + w + slant, y: y + h))
                p.line(to: NSPoint(x: x + w, y: y))
                p.line(to: NSPoint(x: x, y: y))
                p.close()
                p.fill()
            }
            return true
        }
    }
}
