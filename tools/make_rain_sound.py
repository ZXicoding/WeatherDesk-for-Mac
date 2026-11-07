#!/usr/bin/env python3
"""
离线合成三档真实感雨声（16-bit, 44.1kHz, 立体声, 无缝循环）：
  rain-light.wav  毛毛雨：稀疏小水滴的高频「嗒嗒」，底噪极轻
  rain-mid.wav    常规雨：中速雨滴群 + 沙沙雨幕 + 轻微低频滚鸣
  rain-heavy.wav  大雨/雷暴：密集大水滴 + 强嘶嘶 + 明显低频滚鸣 + 偶发大滴「啪」

声学模型（物理化合成，非简单滤波噪声）：
  · 单颗雨滴撞击 = 阻尼正弦共振（滴径越大频率越低，带轻微下滑音高）
    + 攻击瞬态（4kHz~9kHz 短促「嗒」）
  · 雨滴到达 = 泊松过程，强度随档位上升；滴幅重尾分布（多数小、偶发大）
  · 雨滴落点环绕采样缓冲（modulo），天然无缝循环
  · 雨幕嘶嘶 = 密集雨滴群的统计等效（FFT 带通整形白噪）
  · 低频滚鸣 = 远处雨幕/风（30~250Hz），带整数周期起伏保证循环无缝
  · 立体声 = 左右通道各自独立的雨滴流 + 相关底噪（轻微去相关）

输出到 ../Resources/，由 build.sh 拷入 App。
"""
import math
import os
import numpy as np
import wave

SR = 44100
DUR = 24.0
N = int(SR * DUR)
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(__file__)), "Resources")


def fft_band(x: np.ndarray, lo: float, hi: float, order: float = 2.0) -> np.ndarray:
    """FFT 带通（快速，避免逐样本 Python 循环）。"""
    X = np.fft.rfft(x)
    f = np.fft.rfftfreq(len(x), 1.0 / SR)
    g = 1.0 / (1.0 + (lo / (f + 1e-9)) ** order) / (1.0 + (f / hi) ** order)
    return np.fft.irfft(X * g, len(x))


def fft_lp(x: np.ndarray, fc: float) -> np.ndarray:
    return fft_band(x, 1e-6, fc, order=2.0)


def add_drops(buf: np.ndarray, rng: np.random.Generator, rate: float,
              f_lo: float, f_hi: float, tau_lo: float, tau_hi: float,
              amp_scale: float, tail_shape: float) -> None:
    """泊松到达的雨滴撞击流（带环绕），滴径→共振频率映射。"""
    count = int(rng.poisson(rate * DUR))
    for _ in range(count):
        t0 = int(rng.integers(0, N))
        # 滴径大致决定共振频率：小滴高频，大滴低频
        size = rng.random() ** 1.6                      # 偏小滴
        f0 = f_hi - (f_hi - f_lo) * size
        tau = tau_lo + (tau_hi - tau_lo) * size         # 大滴衰减更慢
        amp = amp_scale * (1.0 + rng.pareto(tail_shape))
        amp = min(amp, amp_scale * 8.0)                 # 截断极端值
        dur = min(tau * 6.0, 0.12)
        L = max(int(dur * SR), 8)
        t = np.arange(L) / SR
        # 下滑音高（真实水滴共振随水面扰动略降调）
        f = f0 * (1.0 - 0.15 * (t / dur))
        phase = 2.0 * math.pi * np.cumsum(f) / SR
        s = amp * np.exp(-t / tau) * np.sin(phase)
        # 攻击瞬态：极短高频「嗒」
        la = max(int(0.004 * SR), 2)
        ta = np.arange(la) / SR
        s[:la] += amp * 0.6 * np.exp(-ta / 0.0012) * \
            np.sin(2.0 * math.pi * rng.uniform(4000, 9000) * ta)
        idx = (t0 + np.arange(L)) % N                   # 环绕写入 => 无缝
        buf[idx] += s


def gust_mod(rng: np.random.Generator, strength: float) -> np.ndarray:
    """整数个周期的慢起伏（风吹式强弱），首尾相接无缝。"""
    t = np.arange(N) / SR
    m = np.ones(N)
    for k, a in ((1, strength), (3, strength * 0.6), (7, strength * 0.3)):
        m += a * np.sin(2.0 * math.pi * k * t / DUR + rng.uniform(0, 2 * math.pi))
    return m


def bed_components(rng: np.random.Generator) -> tuple:
    """雨幕嘶嘶 + 低频滚鸣（立体声共享基床，各加独立去相关分量）。"""
    whiteL = rng.standard_normal(N)
    whiteR = rng.standard_normal(N)
    brown = np.cumsum(rng.standard_normal(N)) / SR
    brown -= brown.mean()
    brown /= (np.max(np.abs(brown)) + 1e-9)
    rumble = fft_band(brown, 30, 250) * gust_mod(rng, 0.14)
    return whiteL, whiteR, rumble


def make_variant(rng: np.random.Generator, spec: dict) -> np.ndarray:
    dropsL = np.zeros(N)
    dropsR = np.zeros(N)
    add_drops(dropsL, rng, spec["rate"], spec["f_lo"], spec["f_hi"],
              spec["tau_lo"], spec["tau_hi"], spec["amp"], spec["tail"])
    add_drops(dropsR, rng, spec["rate"], spec["f_lo"], spec["f_hi"],
              spec["tau_lo"], spec["tau_hi"], spec["amp"], spec["tail"])

    whiteL, whiteR, rumble = bed_components(rng)
    hissL = fft_band(whiteL, spec["hiss_lo"], spec["hiss_hi"]) * spec["hiss"]
    hissR = fft_band(whiteR, spec["hiss_lo"], spec["hiss_hi"]) * spec["hiss"]
    # 底噪随整体强度做同样的起伏，听感一致
    mod = gust_mod(rng, 0.10)
    hissL *= mod
    hissR *= mod

    left = dropsL + hissL + rumble * spec["rumble"]
    right = dropsR + hissR + rumble * spec["rumble"] * 0.92

    # 尾部 0.3s 交叉淡化叠回头部（底噪是平稳过程，环接处无爆音）
    win = int(0.3 * SR)
    ramp = np.linspace(1.0, 0.0, win)
    for ch in (left, right):
        ch[:win] += ch[-win:] * ramp

    # 按目标 RMS 归一（档位间响度关系正确），并防削波
    target_rms = spec["rms"]
    rms = math.sqrt(float(np.mean(left ** 2 + right ** 2)) / 2.0)
    gain = target_rms / (rms + 1e-9)
    left *= gain
    right *= gain
    peak = max(float(np.max(np.abs(left))), float(np.max(np.abs(right))))
    if peak > 0.92:
        left *= 0.92 / peak
        right *= 0.92 / peak
    return np.column_stack((left, right))


VARIANTS = {
    # 毛毛雨：稀疏(~55/s)小滴高频嗒嗒，嘶嘶极轻，几乎无滚鸣
    "light": dict(rate=55, f_lo=2400, f_hi=7000, tau_lo=0.006, tau_hi=0.018,
                  amp=0.05, tail=2.2, hiss=0.05, hiss_lo=2500, hiss_hi=9500,
                  rumble=0.05, rms=0.040),
    # 常规雨：中速(~240/s)混合滴径，明显雨幕嘶嘶 + 轻滚鸣
    "mid": dict(rate=240, f_lo=900, f_hi=5200, tau_lo=0.010, tau_hi=0.035,
                amp=0.09, tail=1.8, hiss=0.16, hiss_lo=1600, hiss_hi=9000,
                rumble=0.35, rms=0.085),
    # 大雨/雷暴：密集(~700/s)大滴低频啪声 + 强嘶嘶 + 明显滚鸣
    "heavy": dict(rate=700, f_lo=450, f_hi=3600, tau_lo=0.014, tau_hi=0.055,
                  amp=0.15, tail=1.5, hiss=0.30, hiss_lo=1100, hiss_hi=8500,
                  rumble=0.75, rms=0.150),
}


def main() -> None:
    os.makedirs(OUT_DIR, exist_ok=True)
    for name, spec in VARIANTS.items():
        rng = np.random.default_rng(abs(hash(name)) % (2 ** 31) + 20261107)
        stereo = make_variant(rng, spec)
        out_path = os.path.join(OUT_DIR, f"rain-{name}.wav")
        with wave.open(out_path, "wb") as w:
            w.setnchannels(2)
            w.setsampwidth(2)
            w.setframerate(SR)
            w.writeframes((stereo * 32767).astype("<i2").tobytes())
        print(f"✓ {out_path}  ({DUR:.0f}s, {os.path.getsize(out_path)//1024} KB)")


if __name__ == "__main__":
    main()
