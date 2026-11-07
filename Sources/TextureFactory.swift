import AppKit
import CoreGraphics

/// 程序化生成的「有体积」的位图纹理。
///
/// 之前用 CAShapeLayer 拼云、用纯白细线画雨，看起来像图标。
/// 这里改用分形噪声（value noise + fBm）一次性烘焙出云的形状遮罩、雾的密度、
/// 雨滴的运动拖影、雪花晶体和月面明暗；生成的 CGImage 在进程内共享，
/// 运行时只有 GPU 合成与 CAAnimation，不再逐帧占用 CPU。
enum TextureFactory {

    // MARK: - 分形噪声

    private struct Noise {
        let seed: UInt32

        @inline(__always) func hash(_ x: Int, _ y: Int) -> Double {
            var h = UInt32(truncatingIfNeeded: x &* 374761393)
                ^ UInt32(truncatingIfNeeded: y &* 668265263)
                ^ seed
            h = h &* 1274126177
            h ^= h >> 16
            return Double(h & 0xFFFF) / 65535.0
        }

        @inline(__always) func value(_ x: Double, _ y: Double) -> Double {
            let xi = Int(floor(x)), yi = Int(floor(y))
            let tx = x - floor(x), ty = y - floor(y)
            let sx = tx * tx * (3 - 2 * tx)
            let sy = ty * ty * (3 - 2 * ty)
            let a = hash(xi, yi), b = hash(xi + 1, yi)
            let c = hash(xi, yi + 1), d = hash(xi + 1, yi + 1)
            let top = a + (b - a) * sx
            let bot = c + (d - c) * sx
            return top + (bot - top) * sy
        }

        @inline(__always) func fbm(_ x: Double, _ y: Double, _ octaves: Int) -> Double {
            var sum = 0.0, amp = 0.5, freq = 1.0, norm = 0.0
            for _ in 0..<octaves {
                sum += amp * value(x * freq, y * freq)
                norm += amp
                amp *= 0.5
                freq *= 2.02
            }
            return sum / norm
        }
    }

    @inline(__always) private static func clamp(_ v: Double) -> Double { min(1, max(0, v)) }

    @inline(__always) private static func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        let t = clamp((x - a) / (b - a))
        return t * t * (3 - 2 * t)
    }

    /// 直接写位图内存。CGBitmapContext 的第 0 行对应图像顶部，
    /// 因此涉及「上下」的语义统一用 v = 1 - y/(h-1)（v=1 为顶）。
    private static func bitmap(_ w: Int, _ h: Int,
                               _ pixel: (Int, Int, UnsafeMutablePointer<UInt8>) -> Void) -> CGImage {
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let data = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let bpr = ctx.bytesPerRow
        for y in 0..<h {
            let row = data + y * bpr
            for x in 0..<w { pixel(x, y, row + x * 4) }
        }
        return ctx.makeImage()!
    }

    /// 白色 + 可变 alpha（premultiplied）。用作 CALayer.mask 时只有 alpha 生效。
    @inline(__always) private static func white(_ p: UnsafeMutablePointer<UInt8>, _ a: Double) {
        let v = UInt8(clamp(a) * 255)
        p[0] = v; p[1] = v; p[2] = v; p[3] = v
    }

    /// 带颜色的软光斑（premultiplied），用于星点按其色温着色
    @inline(__always) private static func tinted(_ p: UnsafeMutablePointer<UInt8>,
                                                  _ c: (Double, Double, Double), _ a: Double) {
        let v = clamp(a)
        p[0] = UInt8(c.0 * 255 * v)
        p[1] = UInt8(c.1 * 255 * v)
        p[2] = UInt8(c.2 * 255 * v)
        p[3] = UInt8(255 * v)
    }

    /// 恒星光斑按 B-V 分 5 档色温：蓝白 → 白 → 橙红
    static let starTints: [(Double, Double, Double)] = [
        (0.70, 0.82, 1.00), (0.86, 0.92, 1.00), (1.00, 1.00, 1.00),
        (1.00, 0.95, 0.84), (1.00, 0.80, 0.63),
    ]

    static func tintIndex(bv: Double) -> Int {
        bv < 0.0 ? 0 : bv < 0.30 ? 1 : bv < 0.62 ? 2 : bv < 1.05 ? 3 : 4
    }

    /// 柔和光晕：星点光斑、闪烁、银河雾斑共用
    static let softBlob: CGImage = {
        let s = 96
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let d = hypot(dx, dy)
            let a = exp(-d * d * 7.5) * (1 - smoothstep(0.72, 1.0, d))
            white(p, a)
        }
    }()

    /// 5 档色温的恒星光晕，绘制时直接 draw，不再逐像素上色
    static let starGlows: [CGImage] = (0..<5).map { k in
        let s = 96
        let c = starTints[k]
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let d = hypot(dx, dy)
            let core = exp(-d * d * 90)
            let halo = exp(-d * d * 9)
            let a = clamp((core * 0.85 + halo * 0.42) * (1 - smoothstep(0.78, 1.0, d)))
            tinted(p, c, a)
        }
    }

    /// 银河雾斑：比星点光晕更冷、更散
    static let milkyBlob: CGImage = {
        let s = 96
        let c = (0.70, 0.80, 1.00)
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let d = hypot(dx, dy)
            tinted(p, c, exp(-d * d * 5.2) * (1 - smoothstep(0.70, 1.0, d)))
        }
    }()

    /// 流星拖尾：右端是亮头，向左渐隐
    static let meteorStreak: CGImage = {
        let w = 160, h = 10
        return bitmap(w, h) { x, y, p in
            let u = Double(x) / Double(w - 1)
            let v = Double(y) / Double(h - 1)
            let along = pow(u, 2.3) * 0.92 + 0.04
            let across = pow(sin(Double.pi * v), 1.4)
            white(p, along * across)
        }
    }()

    /// 亮星的衍射十字星芒（望远镜/肉眼眯眼时的光芒）
    static let starSpikes: [CGImage] = (0..<5).map { k in
        let s = 128
        let c = starTints[k]
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let horiz = exp(-dy * dy * 5200) * exp(-abs(dx) * 4.2)
            let vert = exp(-dx * dx * 5200) * exp(-abs(dy) * 4.2)
            let a = clamp((horiz + vert) * 0.52 * (1 - smoothstep(0.72, 1.0, hypot(dx, dy))))
            tinted(p, c, a)
        }
    }

    // MARK: - 云：柔和边缘 + 团块厚度

    /// 6 个不同形态的云遮罩。alpha 同时编码了厚度：厚的团块更实，薄的边缘透出天空。
    static let cloudMasks: [CGImage] = (0..<6).map { seed in
        let w = 448, h = 200
        let n = Noise(seed: UInt32(seed * 7919 + 17))
        return bitmap(w, h) { x, y, p in
            let u = Double(x) / Double(w - 1)
            let v = 1 - Double(y) / Double(h - 1)      // 1 = 云顶
            let fx = Double(x), fy = Double(y)
            let big = n.fbm(fx / 86 + Double(seed) * 2.7, fy / 86 + Double(seed) * 1.3, 3)
            let fine = n.fbm(fx / 34 + 11, fy / 34 + 7, 4)
            let noise = big * 0.62 + fine * 0.38

            // 几个交叠的圆弧团，构成积云的隆起轮廓；底部压平
            let bumps = max(
                1 - hypot((u - 0.30) / 0.29, (v - 0.46) / 0.44),
                max(1 - hypot((u - 0.55) / 0.34, (v - 0.52) / 0.52),
                    1 - hypot((u - 0.77) / 0.24, (v - 0.44) / 0.36)))
            var shape = bumps + (noise - 0.5) * 0.78

            let baseFade = smoothstep(0.04, 0.30, v)   // 云底平、略散
            let topFade = 1 - smoothstep(0.90, 1.0, v) // 云顶不切边
            let edge = smoothstep(-0.10, 0.26, shape) * baseFade * topFade

            // 四边强制羽化：噪声可能把形状顶到纹理边界，不羽化就会露出矩形硬边
            let feather = smoothstep(0.0, 0.14, u) * (1 - smoothstep(0.86, 1.0, u))
                * smoothstep(0.0, 0.10, v) * (1 - smoothstep(0.90, 1.0, v))

            // 内部密度起伏：同一朵云里也有薄厚，避免「一整块灰饼」
            let body = 0.40 + 0.82 * smoothstep(0.30, 0.76, noise)
            white(p, clamp(edge * body * feather) * 0.96)
        }
    }

    // MARK: - 雨：带运动拖影的雨丝

    /// 头部亮、尾部渐隐，两侧羽化；layer 拉伸后就是一根有速度感的雨丝。
    static let rainStreak: CGImage = {
        let w = 8, h = 96
        return bitmap(w, h) { x, y, p in
            let u = Double(x) / Double(w - 1)
            let t = Double(y) / Double(h - 1)    // 0 顶(尾) → 1 底(头)
            // 头部亮、尾部拖影渐隐；整体保留一层底亮，否则叠上半透明后几乎看不见
            let along = 0.10 + 0.90 * pow(t, 1.15)
            let across = pow(sin(Double.pi * u), 0.62)
            white(p, along * across)
        }
    }()

    /// 雨落在地面溅起的水花光环（一圈由内向外扩散并淡出）。
    static let splashRing: CGImage = {
        let s = 48
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let d = hypot(dx, dy)
            let ring = exp(-pow((d - 0.62) * 7.0, 2))
            white(p, ring * (1 - smoothstep(0.72, 1.0, d)) * 0.9)
        }
    }()

    // MARK: - 雪：亮核 + 柔光 + 六角辐条

    static let snowflake: CGImage = {
        let s = 72
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let d = hypot(dx, dy)
            if d > 1 { white(p, 0); return }
            let core = exp(-d * d * 30)
            let halo = exp(-d * d * 4.2)
            let angle = atan2(dy, dx)
            let arms = pow(abs(cos(3 * angle)), 22) * exp(-d * d * 7) * 0.34
            white(p, clamp((core * 0.92 + halo * 0.36 + arms)
                           * (1 - smoothstep(0.86, 1.0, d))))
        }
    }()

    // MARK: - 雾：不均匀的密度带

    static let fogMasks: [CGImage] = (0..<3).map { seed in
        let w = 512, h = 192
        let n = Noise(seed: UInt32(seed * 5171 + 331))
        return bitmap(w, h) { x, y, p in
            let v = 1 - Double(y) / Double(h - 1)
            let fade = smoothstep(0.0, 0.42, v) * (1 - smoothstep(0.62, 1.0, v))
            let d = n.fbm(Double(x) / 108 + Double(seed) * 3, Double(y) / 74, 4)
            let density = smoothstep(0.30, 0.70, d) * fade
            white(p, density * 0.82)
        }
    }

    // MARK: - 月面：球面明暗 + 月海暗斑

    static let moonSurface: CGImage = {
        let s = 128
        let n = Noise(seed: 90210)
        // 几块固定「月海」，让月亮不是一颗纯白圆点
        let maria: [(Double, Double, Double, Double)] = [
            (-0.28, 0.26, 0.30, 0.22), (0.22, 0.34, 0.26, 0.18),
            (0.30, -0.18, 0.24, 0.26), (-0.12, -0.34, 0.32, 0.18),
        ]
        return bitmap(s, s) { x, y, p in
            let dx = (Double(x) / Double(s - 1) - 0.5) * 2
            let dy = (Double(y) / Double(s - 1) - 0.5) * 2
            let d = hypot(dx, dy)
            if d > 1 { p[0] = 0; p[1] = 0; p[2] = 0; p[3] = 0; return }
            let limb = sqrt(max(0, 1 - d * d))
            let grain = n.fbm(Double(x) / 13, Double(y) / 13, 4)
            var lum = (0.60 + 0.40 * limb) * (0.84 + 0.30 * grain)
            for m in maria {
                let q = hypot((dx - m.0) / m.2, (dy - m.1) / m.3)
                lum *= 1 - 0.30 * (1 - smoothstep(0.5, 1.0, q))
            }
            let a = clamp(1 - smoothstep(0.93, 1.0, d))
            let l = clamp(lum) * a   // premultipliedLast：RGB 必须预乘 alpha
            p[0] = UInt8(l * 246)   // 略偏冷白
            p[1] = UInt8(l * 249)
            p[2] = UInt8(l * 255)
            p[3] = UInt8(a * 255)
        }
    }()
}
