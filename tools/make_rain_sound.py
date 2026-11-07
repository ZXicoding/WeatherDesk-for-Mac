#!/usr/bin/env python3
"""
离线合成一段可无缝循环的「雨声」WAV（16-bit, 44.1kHz, 立体声）。
不依赖任何外部音频素材，纯 numpy 噪声 + 滤波生成：
  · 低频隆隆（棕噪 lowpass）          -> 雨的「厚度」
  · 中频沙沙（白噪 lowpass ~2.5k）      -> 雨幕底噪
  · 高频嘶嘶（带通 0.8k~7k）           -> 雨打地面的细碎感
  · 随机水滴「叮」声（短衰减带通脉冲）  -> 真实感
输出：../WeatherDesk/Resources/rain.wav（相对本脚本）
"""
import math
import os
import numpy as np
import wave

SR = 44100
DUR = 20.0
N = int(SR * DUR)


def lp(x: np.ndarray, a: float) -> np.ndarray:
    """一阶低通，alpha 由截止频率决定。"""
    y = np.empty_like(x)
    y[0] = x[0]
    for i in range(1, len(x)):
        y[i] = y[i - 1] + a * (x[i] - y[i - 1])
    return y


def alpha(fc: float) -> float:
    return 1.0 - math.exp(-2.0 * math.pi * fc / SR)


def bp(x: np.ndarray, f_lo: float, f_hi: float) -> np.ndarray:
    """带通 = lowpass(f_hi) - lowpass(f_lo)。"""
    return lp(x, alpha(f_hi)) - lp(x, alpha(f_lo))


def main() -> None:
    rng = np.random.default_rng(20261107)
    white = rng.standard_normal(N)
    brown = np.cumsum(white) / SR
    brown -= brown.mean()
    brown /= (np.max(np.abs(brown)) + 1e-9)

    body = lp(brown, alpha(500)) * 0.55          # 低频隆隆
    mid = lp(white, alpha(2500)) * 0.22          # 中频沙沙
    hiss = bp(white, 800, 7000) * 0.16           # 高频嘶嘶

    mix = body + mid + hiss

    # 随机水滴「叮」声：短指数衰减的带通脉冲
    drops = np.zeros(N)
    n_drops = 90
    env_len = int(0.04 * SR)  # 40ms
    for _ in range(n_drops):
        t = rng.integers(0, N - env_len)
        burst = rng.standard_normal(env_len)
        burst = bp(burst, 2500, 8000)
        env = np.exp(-np.linspace(0, 7, env_len))
        drops[t:t + env_len] += burst * env * 0.5
    mix += drops

    # 归一化到约 -16 dBFS（峰值 ~0.16），保持「轻微」
    peak = np.max(np.abs(mix)) + 1e-9
    mix *= (0.16 / peak)

    # 无缝循环：把尾部 0.3s 淡出叠加到开头，再裁掉尾部
    win = int(0.3 * SR)
    tail = mix[-win:].copy()
    ramp = np.linspace(1.0, 0.0, win)
    mix[:win] += tail * ramp
    mix = mix[:-win]

    # 立体声：复制单声道，右声道加极轻微去相关
    left = mix
    right = mix + rng.standard_normal(len(mix)) * 0.01 * np.max(np.abs(mix))
    right /= (np.max(np.abs(right)) + 1e-9) * (1.0 / 0.16)

    pcm_l = (left * 32767).astype("<i2")
    pcm_r = (right * 32767).astype("<i2")
    stereo = np.column_stack((pcm_l, pcm_r)).ravel()

    out_dir = os.path.join(os.path.dirname(os.path.dirname(__file__)), "Resources")
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, "rain.wav")
    with wave.open(out_path, "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(stereo.tobytes())

    print(f"✓ 生成雨声：{out_path}  ({len(left)/SR:.1f}s, {os.path.getsize(out_path)//1024} KB)")


if __name__ == "__main__":
    main()
