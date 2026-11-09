#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成高清「主图」12 档：scene-h00.jpg … scene-h22.jpg

做法：当前磁盘上的 scene-hHH.jpg 是 v1.5.0/1.5.1 已随 App 发布、用户确认过的
1536×924 主图。本脚本把每张 1536 主图，按其来源基底（高清版）反推裁剪窗口，
裁出高清基底对应区域，再用「1536 主图 vs 其基底」的逐通道仿射 + 饱和度标定，
把当年那套时间光照复刻到高清图上，从而既保留已确认的时段氛围，又在大屏清晰。

基底来源映射（与 Resources/图片来源.txt 主图一节一致）：
  h00 夜水面      <- night   h02 苇线水面    <- rain
  h04 黎明草甸    <- clear   h06 日出水面    <- sunset
  h08 清晨水面    <- rain    h10 上午草甸    <- clear
  h12 正午水面    <- rain    h14 午后草甸    <- clear
  h16 傍晚水面    <- night   h18 日落水面    <- sunset
  h20 入夜水面    <- rain    h22 深夜草甸    <- clear

用法： python3 tools/gen_main_slots.py
"""
import os
import sys
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
PHOTOS = os.path.join(ROOT, "Resources", "photos")
BIOMES = os.path.join(ROOT, "Resources", "biomes", "wetland")
TGT_W, TGT_H = 3840, 2310
ASPECT = TGT_W / TGT_H
QUALITY = 88

SLOTS = {
    0:  "night", 2:  "rain", 4:  "clear", 6:  "sunset",
    8:  "rain", 10: "clear", 12: "rain", 14: "clear",
    16: "night", 18: "sunset", 20: "rain", 22: "clear",
}


def luma_key(im):
    return np.asarray(im.convert("L").resize((192, 116), Image.BILINEAR)).astype(np.float32)


def recover_window(O, V):
    Wo, Ho = O.size
    Vk = luma_key(V)
    ch_hi = min(Ho, int(Wo / ASPECT))
    ch_lo = max(240, int(Ho * 0.30))
    n_ch = 24
    best = None

    def match(xi, yi, cw, ch):
        sub = O.crop((xi, yi, xi + cw, yi + ch)).resize((192, 116), Image.BILINEAR)
        sk = luma_key(sub)
        return np.mean(np.abs(Vk - sk))
    for k in range(n_ch + 1):
        ch = ch_lo + (ch_hi - ch_lo) * k // n_ch
        cw = int(ch * ASPECT)
        if cw <= 0 or cw > Wo or ch > Ho:
            continue
        for xi in range(0, Wo - cw + 1, max(1, (Wo - cw) // 6)):
            for yi in range(0, Ho - ch + 1, max(1, (Ho - ch) // 6)):
                d = match(xi, yi, cw, ch)
                if best is None or d < best[0]:
                    best = (d, cw, ch, xi, yi)
    _, cw, ch, x0, y0 = best
    base_k = next((k for k in range(n_ch + 1)
                   if ch_lo + (ch_hi - ch_lo) * k // n_ch == ch), None)
    for k in range(max(0, (base_k or 0) - 3), min(n_ch, (base_k or 0) + 4)):
        nch = ch_lo + (ch_hi - ch_lo) * k // n_ch
        ncw = int(nch * ASPECT)
        if ncw <= 0 or ncw > Wo or nch > Ho:
            continue
        for xi in range(max(0, x0 - ncw // 24), min(Wo - ncw, x0 + ncw // 24) + 1, max(1, ncw // 24)):
            for yi in range(max(0, y0 - nch // 24), min(Ho - nch, y0 + nch // 24) + 1, max(1, nch // 24)):
                d = match(xi, yi, ncw, nch)
                if d < best[0]:
                    best = (d, ncw, nch, xi, yi)
    return best[1:]


def fit_grade(base_small, main):
    """base_small / main 都是 1536×924 同内容。返回：逐通道仿射、饱和度比例、
    以及残差图（main - 仿射+饱和后的 base_small），残差是平滑的天空渐变等非线性部分，
    高清化时直接放大叠加即可保留原时段氛围。"""
    b = np.asarray(base_small).astype(np.float32) / 255.0
    m = np.asarray(main).astype(np.float32) / 255.0
    aff = []
    for c in range(3):
        x = b[..., c].ravel(); y = m[..., c].ravel()
        if x.std() < 1e-4:
            aff.append((1.0, y.mean() - x.mean()))
        else:
            a = np.cov(x, y)[0, 1] / np.var(x)
            bb = y.mean() - a * x.mean()
            aff.append((a, bb))
    # 先套用仿射 + 饱和度，再算残差
    g0 = np.empty_like(b)
    for c in range(3):
        g0[..., c] = np.clip(b[..., c] * aff[c][0] + aff[c][1], 0.0, 1.0)
    sat = lambda arr: np.mean((arr.max(2) - arr.min(2)))
    sm = sat(m); sb = sat(g0)
    sat_ratio = (sm / sb) if sb > 1e-4 else 1.0
    if sat_ratio != 1.0:
        g = g0.mean(2, keepdims=True)
        g0 = np.clip(g + (g0 - g) * sat_ratio, 0.0, 1.0)
    residual = np.clip(m - g0, -1.0, 1.0)
    return aff, sat_ratio, residual


def apply_grade(crop_hi, aff, sat_ratio, residual):
    a = np.asarray(crop_hi).astype(np.float32) / 255.0
    out = np.empty_like(a)
    for c in range(3):
        out[..., c] = np.clip(a[..., c] * aff[c][0] + aff[c][1], 0.0, 1.0)
    if sat_ratio != 1.0:
        g = out.mean(2, keepdims=True)
        out = np.clip(g + (out - g) * sat_ratio, 0.0, 1.0)
    # 残差（天空渐变等非线性部分）以 0 为中心：映射到 0..255 再放大，避免偏移
    res8 = np.clip((residual + 1.0) * 127.5, 0, 255).astype(np.uint8)
    res_hi = (np.asarray(Image.fromarray(res8).resize(
        (a.shape[1], a.shape[0]), Image.BILINEAR)).astype(np.float32) / 255.0 * 2.0 - 1.0)
    out = np.clip(out + res_hi, 0.0, 1.0)
    return Image.fromarray((np.clip(out, 0, 1) * 255).astype(np.uint8), "RGB")


def main():
    for h, base_name in SLOTS.items():
        m_path = os.path.join(PHOTOS, "scene-h%02d.jpg" % h)
        b_path = os.path.join(PHOTOS, "scene-%s.jpg" % base_name)
        if not os.path.exists(m_path) or not os.path.exists(b_path):
            sys.exit("缺少文件：" + m_path + " / " + b_path)
        M = Image.open(m_path).convert("RGB")
        B = Image.open(b_path).convert("RGB")
        cw, ch, x0, y0 = recover_window(B, M)
        crop = B.crop((x0, y0, x0 + cw, y0 + ch)).resize((TGT_W, TGT_H), Image.LANCZOS)
        b_small = B.crop((x0, y0, x0 + cw, y0 + ch)).resize((1536, 924), Image.LANCZOS)
        aff, sat_ratio, residual = fit_grade(b_small, M)
        out = apply_grade(crop, aff, sat_ratio, residual)
        out.save(os.path.join(PHOTOS, "scene-h%02d.jpg" % h), quality=QUALITY, optimize=True)
        if os.path.isdir(BIOMES):
            out.save(os.path.join(BIOMES, "scene-h%02d.jpg" % h), quality=QUALITY, optimize=True)
        sys.stderr.write("  h%02d <- %s  window %sx%s @(%d,%d) sat=%.2f\n"
                         % (h, base_name, cw, ch, x0, y0, sat_ratio))


if __name__ == "__main__":
    main()
