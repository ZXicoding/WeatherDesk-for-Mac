import AppKit
import AVFoundation

/// 下雨时播放轻微雨声，音量随雨量与强度自动变化。
///
/// 素材是内嵌在 App 里的 `rain.wav`（循环播放，由 `tools/make_rain_sound.py` 离线合成，
/// 不依赖任何外部音频文件、无版权问题）。非雨天自动淡出停止。
final class RainAudio {
    static let shared = RainAudio()

    private var player: AVAudioPlayer?
    private var ramp: Timer?
    private var current: Float = 0
    private var target: Float = 0
    private var playing = false

    /// App 启动时调用一次：载入内嵌雨声素材。
    func configure() {
        guard let url = Bundle.main.url(forResource: "rain", withExtension: "wav") else {
            print("RainAudio: 找不到 rain.wav")
            return
        }
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.numberOfLoops = -1
            player?.volume = 0
            player?.prepareToPlay()
        } catch {
            print("RainAudio: 载入失败 \(error)")
        }
    }

    /// 依据当前天气更新雨声：非雨天 -> 淡出停止；雨天 -> 按雨量设定目标音量。
    func update(for w: Weather) {
        guard Settings.shared.rainSoundEnabled else { setTarget(0); return }
        setTarget(volume(for: w))
    }

    /// 立即停止（总开关关闭、退出时调用）。
    func stop() { setTarget(0) }

    /// 目标音量：按天气类型给基础值，再按实际降雨量（mm）微调；雨越大越响。
    private func volume(for w: Weather) -> Float {
        guard w.condition.isRainy else { return 0 }
        let base: Float
        switch w.condition {
        case .drizzle:               base = 0.14
        case .rain, .sleet:          base = 0.32
        case .heavyRain, .thunder:   base = 0.55
        default:                     base = 0
        }
        // 实际降雨量（mm）再微调：雨越大越响，但保留下限让小雨也听得见
        let p = min(1, Float(w.precipitation) / 12.0)
        let scaled = base * (0.6 + 0.4 * p)
        return scaled * Float(Settings.shared.rainSoundVolume)
    }

    private func setTarget(_ v: Float) {
        target = max(0, min(1, v))
        if target > 0, !playing, let p = player {
            p.volume = current
            p.play()
            playing = true
        }
        ramp?.invalidate()
        // 100ms 一档做平滑淡入淡出，避免突兀
        ramp = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            let diff = self.target - self.current
            if abs(diff) < 0.01 {
                self.current = self.target
                self.player?.volume = self.current
                if self.target == 0, self.playing {
                    self.player?.stop()
                    self.playing = false
                }
                t.invalidate()
                return
            }
            self.current += diff * 0.25
            self.player?.volume = self.current
        }
    }
}
