import AppKit
import QuartzCore

/// 真实星空的绘制。
///
/// 星点不是随机撒的：每一颗都来自依巴谷星表，按观测地的经纬度、当前恒星时、
/// 岁差和大气折射算出高度角 / 方位角，再用与太阳、月亮、行星完全相同的
/// 立体投影落到屏幕上。星等决定大小与亮度，B-V 决定颜色，月光与暮光决定
/// 当晚能看到几等星。银河沿银道面铺雾斑，亮星带衍射星芒与视宁度闪烁。
private enum StarImageCache {
    static var key = ""
    static var image: CGImage?
    static var count = 0
}

extension SkyView {

    /// 返回当前画面里真实可见的星数（用于角标）
    func updateStarField(frame: SkyFrame) -> Int {
        let W = Int(bounds.width), H = Int(bounds.height)
        guard W > 1, H > 1 else { return 0 }
        let labels = forceStarLabels ?? Settings.shared.showConstellations
        let slot = Int(frame.date.timeIntervalSince1970 / 20)
        let key = "\(slot)|\(Int(frame.latDeg * 100))|\(Int(frame.lonDeg * 100))"
            + "|\(W)x\(H)|\(labels ? 1 : 0)|\(Int(frame.limitMag * 10))"

        if key == StarImageCache.key, let img = StarImageCache.image {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            starField.contents = img
            CATransaction.commit()
            return StarImageCache.count
        }

        let size = CGSize(width: W, height: H)
        let stars = frame.projectedStars(size: size)
        let img = makeStarImage(size: size, frame: frame, stars: stars, lines: labels)
        StarImageCache.key = key
        StarImageCache.image = img
        StarImageCache.count = stars.count

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        starField.contents = img
        CATransaction.commit()
        rebuildTwinkles(stars: stars, size: size)
        rebuildLabels(stars: stars, frame: frame, size: size, show: labels)
        return stars.count
    }

    // MARK: 位图

    private func makeStarImage(size: CGSize, frame: SkyFrame,
                               stars: [ProjectedStar], lines: Bool) -> CGImage? {
        let w = Int(size.width), h = Int(size.height)
        guard let ctx = CGContext(data: nil, width: w, height: h,
                                  bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        // CGBitmapContext 原点在左下，与 SkyFrame.project 的 y 定义一致
        drawMilkyWay(ctx: ctx, frame: frame, size: size)
        if lines { drawConstellationLines(ctx: ctx, frame: frame, stars: stars, size: size) }
        for s in stars.reversed() { drawStar(ctx: ctx, s: s, size: size) }
        drawPlanets(ctx: ctx, frame: frame, size: size)
        return ctx.makeImage()
    }

    /// 银河：沿银道面 (b≈0) 铺一层冷白雾斑，银心方向更亮，中间留暗尘带
    private func drawMilkyWay(ctx: CGContext, frame: SkyFrame, size: CGSize) {
        guard frame.darkness > 0.55 else { return }
        let strength = frame.darkness * max(0, 1 - frame.moonIllumination * 1.5)
        guard strength > 0.04 else { return }
        let lat = frame.latDeg * Double.pi / 180
        let blob = TextureFactory.milkyBlob
        let R = size.width * 0.090
        for li in stride(from: -180, through: 175, by: 5) {
            for bi in [-10, -5, 0, 5, 10] {
                let jl = (Self.hash(Double(li) * 3.1 + Double(bi) * 7.7) - 0.5) * 3.4
                let jb = (Self.hash(Double(li) * 5.3 + Double(bi) * 2.9 + 91) - 0.5) * 3.0
                let eq = Self.galacticToEquatorial(l: Double(li) + jl, b: Double(bi) + jb)
                let hor = Astronomy.toHorizontal(ra: eq.ra, dec: eq.dec,
                                                 lst: frame.lst, lat: lat)
                guard hor.altDeg > -3,
                      let p = frame.project(hor, size: size),
                      p.x > -0.12, p.x < 1.12, p.y > -0.12, p.y < 1.12 else { continue }
                let core = exp(-pow(Double(li) / 68, 2))
                let band = exp(-pow(Double(bi) / 9.5, 2))
                let rift: Double = bi == 0 ? 0.42 : 1.0       // 大暗隙
                let grain = 0.55 + 0.45 * Self.hash(Double(li) * 11 + Double(bi) * 17 + 3)
                let a = strength * (0.045 + 0.10 * core) * band * rift * grain
                ctx.setAlpha(CGFloat(min(0.22, a)))
                let stretch: CGFloat = CGFloat(1 + 0.5 * core)
                let cx: CGFloat = p.x * size.width
                let cy: CGFloat = p.y * size.height
                let bw: CGFloat = R * 2 * stretch
                let bh: CGFloat = R * 1.44
                let rect = CGRect(x: cx - bw / 2, y: cy - bh / 2, width: bw, height: bh)
                ctx.draw(blob, in: rect)
            }
        }
        ctx.setAlpha(1)
    }

    /// 银道坐标 → J2000 赤道坐标（IAU 旋转矩阵的转置）
    private static func galacticToEquatorial(l: Double, b: Double) -> (ra: Double, dec: Double) {
        let L = l * Double.pi / 180, B = b * Double.pi / 180
        let xg = cos(B) * cos(L), yg = cos(B) * sin(L), zg = sin(B)
        let x = -0.0548755604 * xg + 0.4941094279 * yg - 0.8676661490 * zg
        let y = -0.8734370902 * xg - 0.4448296300 * yg - 0.1980763734 * zg
        let z = -0.4838350155 * xg + 0.7469822445 * yg + 0.4559837762 * zg
        return (atan2(y, x), asin(max(-1, min(1, z))))
    }

    private func drawConstellationLines(ctx: CGContext, frame: SkyFrame,
                                        stars: [ProjectedStar], size: CGSize) {
        var map: [Int: CGPoint] = [:]
        for s in stars { map[s.index] = s.point }
        ctx.setStrokeColor(CGColor(red: 0.58, green: 0.72, blue: 1.0, alpha: 0.32))
        ctx.setLineWidth(0.9)
        ctx.beginPath()
        for (a, b) in StarCatalog.lines {
            guard let pa = map[a], let pb = map[b] else { continue }
            ctx.move(to: CGPoint(x: pa.x * size.width, y: pa.y * size.height))
            ctx.addLine(to: CGPoint(x: pb.x * size.width, y: pb.y * size.height))
        }
        ctx.strokePath()
    }

    private func drawStar(ctx: CGContext, s: ProjectedStar, size: CGSize) {
        let px = s.point.x * size.width, py = s.point.y * size.height
        let tint = TextureFactory.tintIndex(bv: s.bv)
        let c = TextureFactory.starTints[tint]
        // 低空星被大气 reddening，偏暖偏红
        let red = max(0, min(1, (28 - s.altDeg) / 28)) * 0.22
        let a = max(0.16, min(1, (6.9 - s.mag) / 7.2))
        let r = max(0.62, (6.8 - s.mag) * 0.19)
        ctx.setFillColor(CGColor(red: min(1, c.0 + red * 0.3),
                                 green: max(0, c.1 - red * 0.18),
                                 blue: max(0, c.2 - red * 0.5),
                                 alpha: a))
        ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))

        if s.mag < 3.2 {
            let g = 5 + (3.2 - s.mag) * 4.2
            ctx.setAlpha(CGFloat(a * 0.68))
            ctx.draw(TextureFactory.starGlows[tint],
                     in: CGRect(x: px - g, y: py - g, width: g * 2, height: g * 2))
        }
        if s.mag < 1.6 {
            let k = 13 + (1.6 - s.mag) * 10
            ctx.setAlpha(CGFloat(a * 0.78))
            ctx.draw(TextureFactory.starSpikes[tint],
                     in: CGRect(x: px - k, y: py - k, width: k * 2, height: k * 2))
        }
        ctx.setAlpha(1)
    }

    /// 行星不眨眼：亮度稳定、颜色固定，是辨认真实星空的一个重要细节
    private func drawPlanets(ctx: CGContext, frame: SkyFrame, size: CGSize) {
        for p in frame.planets {
            guard let q = frame.project(p.position, size: size),
                  q.x > 0, q.x < 1, q.y > 0, q.y < 1 else { continue }
            let px = q.x * size.width, py = q.y * size.height
            let r = max(1.3, min(4.6, (4.2 - p.mag) * 0.62))
            let a = max(0.45, min(1, (6.2 - p.mag) / 5.0))
            let c = p.color
            ctx.setFillColor(CGColor(red: c.0, green: c.1, blue: c.2, alpha: a))
            ctx.fillEllipse(in: CGRect(x: px - r, y: py - r, width: r * 2, height: r * 2))
            let g = r * 4.5
            ctx.setAlpha(CGFloat(a * 0.34))
            ctx.draw(TextureFactory.softBlob,
                     in: CGRect(x: px - g, y: py - g, width: g * 2, height: g * 2))
            ctx.setAlpha(1)
        }
    }

    // MARK: 视宁度闪烁

    private func rebuildTwinkles(stars: [ProjectedStar], size: CGSize) {
        twinkleHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        let bright = stars.filter { $0.mag < 2.1 }.prefix(26)
        for (i, s) in bright.enumerated() {
            let low = max(0, min(1, (32 - s.altDeg) / 32))
            let r: CGFloat = 5 + (2.1 - s.mag) * 2.1
            let l = CALayer()
            l.contents = TextureFactory.starGlows[TextureFactory.tintIndex(bv: s.bv)]
            l.bounds = CGRect(x: 0, y: 0, width: r * 2, height: r * 2)
            l.position = CGPoint(x: s.point.x * size.width, y: s.point.y * size.height)
            let base: Float = 0.40
            l.opacity = base
            let flicker = CABasicAnimation(keyPath: "opacity")
            flicker.fromValue = base * (1 - 0.42 * Float(low))
            flicker.toValue = min(1, base * (1.34 + 0.24 * Float(low)))
            flicker.duration = CFTimeInterval(1.3 + Self.hash(Double(i) * 17 + 5) * 3.4 - low * 0.5)
            flicker.autoreverses = true
            flicker.repeatCount = .infinity
            flicker.timeOffset = flicker.duration * CFTimeInterval(Self.hash(Double(i) * 23 + 9))
            l.add(flicker, forKey: "scintillation")
            twinkleHost.addSublayer(l)
        }
    }

    // MARK: 可选标注层

    private func rebuildLabels(stars: [ProjectedStar], frame: SkyFrame,
                               size: CGSize, show: Bool) {
        labelHost.sublayers?.forEach { $0.removeFromSuperlayer() }
        guard show else { return }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        func text(_ s: String, _ p: CGPoint, _ fontSize: CGFloat,
                  _ alpha: CGFloat, _ dx: CGFloat, _ dy: CGFloat) {
            let t = CATextLayer()
            t.contentsScale = scale
            t.fontSize = fontSize
            t.foregroundColor = NSColor(calibratedWhite: 0.88, alpha: alpha).cgColor
            t.string = s
            t.alignmentMode = .left
            t.frame = CGRect(x: p.x * size.width + dx, y: p.y * size.height + dy,
                             width: 150, height: 20)
            labelHost.addSublayer(t)
        }

        var shown = 0
        for s in stars where s.mag < 2.4 && shown < 7 {
            let hip = StarCatalog.stars[s.index].hip
            if let name = StarCatalog.starNames[hip] {
                text(name, s.point, 12, 0.85, 7, 4)
                shown += 1
            }
        }
        for p in frame.planets {
            if let q = frame.project(p.position, size: size),
               q.x > 0, q.x < 1, q.y > 0, q.y < 1 {
                text(p.name, q, 12, 0.90, 8, 5)
            }
        }

        var groups: [UInt8: (x: CGFloat, y: CGFloat, n: Int)] = [:]
        for s in stars where s.mag < 4.0 {
            let c = StarCatalog.stars[s.index].con
            guard c != 255 else { continue }
            var g = groups[c] ?? (0, 0, 0)
            g.x += s.point.x; g.y += s.point.y; g.n += 1
            groups[c] = g
        }
        let names = StarCatalog.constellations
        let ranked = groups.filter { $0.value.n >= 3 }
            .sorted { $0.value.n > $1.value.n }.prefix(5)
        for (k, g) in ranked where Int(k) < names.count {
            let p = CGPoint(x: g.x / CGFloat(g.n), y: g.y / CGFloat(g.n))
            let zh = StarCatalog.constellationNames[names[Int(k)]] ?? names[Int(k)]
            text(zh, p, 13, 0.72, -22, -10)
        }
    }

    // MARK: 偶发流星

    func scheduleMeteor() {
        guard !meteorScheduled else { return }
        meteorScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Double.random(in: 38...115)) { [weak self] in
            guard let self else { return }
            self.meteorScheduled = false
            if let w = self.weather, w.sky().stars > 0, w.cloudCover < 55,
               Astronomy.frame(place: w.place).darkness > 0.8 {
                self.fireMeteor()
            }
            self.scheduleMeteor()
        }
    }

    private func fireMeteor() {
        let W = bounds.width, H = bounds.height
        let sx = W * CGFloat(Double.random(in: 0.12...0.88))
        let sy = H * CGFloat(Double.random(in: 0.58...0.94))
        let dir: CGFloat = Bool.random() ? 1 : -1
        let len = W * CGFloat(Double.random(in: 0.10...0.19))
        let dx = dir * len * 1.9
        let dy = -H * CGFloat(Double.random(in: 0.16...0.30))
        let angle = atan2(dy, dx)

        let l = CALayer()
        l.contents = TextureFactory.meteorStreak
        l.bounds = CGRect(x: 0, y: 0, width: len, height: 5)
        l.anchorPoint = CGPoint(x: 0.9, y: 0.5)
        l.position = CGPoint(x: sx, y: sy)
        l.transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        l.opacity = 0
        meteorHost.addSublayer(l)

        let move = CABasicAnimation(keyPath: "position")
        move.fromValue = NSValue(point: NSPoint(x: sx, y: sy))
        move.toValue = NSValue(point: NSPoint(x: sx + dx, y: sy + dy))
        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values = [0, 0.95, 0.78, 0] as [NSNumber]
        fade.keyTimes = [0, 0.16, 0.60, 1] as [NSNumber]
        let group = CAAnimationGroup()
        group.animations = [move, fade]
        group.duration = CFTimeInterval(Double.random(in: 0.7...1.15))
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = false
        group.fillMode = .forwards
        l.add(group, forKey: "meteor")
        DispatchQueue.main.asyncAfter(deadline: .now() + group.duration + 0.2) { [weak l] in
            l?.removeFromSuperlayer()
        }
    }

    /// 稳定 hash，保证同一帧里银河斑块和闪烁相位不变（多屏一致）
    private static func hash(_ x: Double) -> Double {
        var h = UInt32(truncatingIfNeeded: Int(x * 8191) &* 2654435761) ^ 0x9E3779B9
        h = h &* 1664525 &+ 1013904223
        h ^= h >> 15
        return Double(h & 0xFFFFFF) / 16777215.0
    }
}
