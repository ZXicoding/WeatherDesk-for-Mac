import AppKit
import AVFoundation

/// 下雨时播放雨声，音量随雨量与强度自动变化。
///
/// 素材是内嵌的三档雨声 `rain-light/mid/heavy.wav`（循环播放，由
/// `tools/make_rain_sound.py` 物理化合成：泊松雨滴撞击 + 雨幕嘶嘶 + 低频滚鸣，
/// 不依赖任何外部音频文件、无版权问题）。
/// 天气档位变化时在音色间交叉淡化；非雨天自动淡出停止。
final class RainAudio {
    static let shared = RainAudio()

    /// 音色档位：与天气强度对应
    private enum Texture: String {
        case light, mid, heavy

        static func forCondition(_ c: Condition) -> Texture {
            switch c {
            case .drizzle:              return .light
            case .rain, .sleet:         return .mid
            case .heavyRain, .thunder:  return .heavy
            default:                    return .light
            }
        }
    }

    private var players: [Texture: AVAudioPlayer] = [:]
    private var active: Texture?
    private var ramp: Timer?
    private var current: Float = 0
    private var target: Float = 0
    private var pending: Texture?

    /// App 启动时调用一次：预载三档雨声素材。
    func configure() {
        for t in [Texture.light, .mid, .heavy] {
            guard let url = Bundle.main.url(forResource: "rain-\(t.rawValue)", withExtension: "wav") else {
                print("RainAudio: 找不到 rain-\(t.rawValue).wav")
                continue
            }
            do {
                let p = try AVAudioPlayer(contentsOf: url)
                p.numberOfLoops = -1
                p.volume = 0
                p.prepareToPlay()
                players[t] = p
            } catch {
                print("RainAudio: 载入 \(t.rawValue) 失败 \(error)")
            }
        }
    }

    /// 依据当前天气更新雨声：非雨天 -> 淡出停止；雨天 -> 选音色并按雨量设定目标音量。
    func update(for w: Weather) {
        guard Settings.shared.rainSoundEnabled else { setTarget(0, texture: nil); return }
        guard w.condition.isRainy else { setTarget(0, texture: nil); return }
        setTarget(volume(for: w), texture: Texture.forCondition(w.condition))
    }

    /// 立即停止（总开关关闭、退出时调用）。
    func stop() { setTarget(0, texture: nil) }

    /// 目标音量：素材本身已按档位定好响度，这里只按实际降雨量（mm）微调。
    private func volume(for w: Weather) -> Float {
        // 降雨量微调：雨越大越响，但保留下限让小雨也听得见
        let p = min(1, Float(w.precipitation) / 12.0)
        return (0.7 + 0.3 * p) * Float(Settings.shared.rainSoundVolume)
    }

    /// 设定目标音量与音色。音色变化时先淡出旧素材再淡入新素材（交叉过渡）。
    private func setTarget(_ v: Float, texture: Texture?) {
        target = max(0, min(1, v))

        if target > 0, let tex = texture {
            if active == tex, let p = players[tex] {
                if !p.isPlaying { p.play() }
                startRamp()
                return
            }
            if let old = active, let op = players[old], op.isPlaying {
                pending = tex                       // 淡出完成后接新音色
                startRamp()
                return
            }
            active = tex
            if let p = players[tex] {
                p.volume = current
                p.play()
            }
            startRamp()
            return
        }

        // target == 0：全部淡出
        pending = nil
        startRamp()
    }

    private func startRamp() {
        ramp?.invalidate()
        // 100ms 一档平滑淡入淡出，避免突兀
        ramp = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let diff = self.target - self.current
            if abs(diff) < 0.01 {
                self.current = self.target
                self.applyVolume()
                if self.target == 0, let a = self.active {
                    self.players[a]?.stop()
                    self.active = nil
                }
                // 旧音色已淡出，新音色从静音淡入
                if self.target > 0, let next = self.pending {
                    self.pending = nil
                    self.active = next
                    if let np = self.players[next] {
                        np.volume = 0
                        np.play()
                        self.current = 0
                        self.startRamp()        // 重新淡入到 target
                        return
                    }
                }
                t.invalidate()
                return
            }
            self.current += diff * 0.25
            self.applyVolume()
        }
    }

    /// 淡出期间把音量衰减也作用到旧素材上。
    private func applyVolume() {
        if let a = active { players[a]?.volume = current }
        if let p = pending {
            // 淡出旧音色的同时，新音色从静音预备（尚未 play，防止叠音）
            players[p]?.volume = 0
        }
    }
}
