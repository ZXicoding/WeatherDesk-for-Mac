#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成「艳阳版」2 小时档位底图：scene-hHH-sun.jpg

背景：v1.5.0 的 12 档底图只按时间分档、不看天气，其中 h08/h12/h20 用的是
同一张阴天灰白大水面，导致大晴天正午桌面也是雾蒙蒙的。这里用同一批已授权
实景素材，离线做确定性的「去雾 + 提亮 + 增饱和 + 蓝天渐变」光照分级，得到
晴天专用的一套 12 档；阴天/雾天继续用原来的主图。

严格约束：
  * 只用 Resources/photos/ 里已有的真实照片，不下载、不生成、不拼接内容；
  * 只做逐像素的确定性调色与轻微取景位移，与 v1.5.0 主图的做法一致；
  * 输出仍是普通 1536×924 JPEG，App 运行时只读文件，不做任何计算。

用法： python3 tools/gen_sunny_slots.py
"""
import os
import sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Resources", "photos")
W, H = 1536, 924
QUALITY = 90

# 源图：全部来自 Resources/图片来源.txt 里已署名的 CC 授权实景照片
BASES = {
    "meadow": "scene-clear.jpg",   # 蓝天白云 + 开阔绿苇草甸（最通透）
    "dusk":   "scene-night.jpg",   # 通透冷蓝 + 开阔水面（傍晚档用）
    "sun":    "scene-sunset.jpg",  # 金色低太阳 + 开阔水面
    "night1": "scene-h00.jpg",     # 深蓝夜水面
    "night2": "scene-h02.jpg",     # 深蓝夜树林水面
    "night3": "scene-h22.jpg",     # 深蓝夜草地
    "dawn":   "scene-h04.jpg",     # 黎明冷调草地
    "twilight": "scene-h20.jpg",   # 暮色树林水面
}

# 每档：(源图 key, 曝光, 色温 RGB, 饱和, 天空色, 天空强度, 对比, 去雾黑场, 取景位移)
# 白天档必须明显比同档主图更亮、更通透、更蓝；相邻档尽量交替不同场景。
PLAN = [
    (0,  "night1",   1.05, (0.93, 0.98, 1.10), 1.06, None,                 0.00, 1.10, 0.03, 0.00),
    (2,  "night2",   1.06, (0.94, 0.98, 1.09), 1.06, None,                 0.00, 1.10, 0.03, 0.20),
    (4,  "dawn",     1.06, (0.91, 0.97, 1.12), 1.12, (0.45, 0.62, 0.86), 0.18, 1.10, 0.05, 0.00),
    (6,  "sun",      1.02, (1.02, 1.00, 0.97), 1.14, None,                 0.00, 1.08, 0.04, 0.30),
    (8,  "meadow",   0.98, (0.92, 0.97, 1.12), 1.12, (0.38, 0.60, 0.90), 0.12, 1.08, 0.05, 0.00),
    (10, "meadow",   1.05, (1.00, 1.00, 1.02), 1.16, (0.40, 0.62, 0.92), 0.08, 1.10, 0.05, 0.50),
    (12, "meadow",   1.10, (1.00, 1.00, 1.01), 1.26, (0.34, 0.58, 0.90), 0.16, 1.13, 0.05, 1.00),
    (14, "meadow",   1.11, (0.99, 1.00, 1.03), 1.24, (0.32, 0.56, 0.90), 0.26, 1.12, 0.05, 0.72),
    (16, "dusk",     1.07, (1.02, 0.99, 0.97), 1.16, (0.55, 0.70, 0.93), 0.12, 1.10, 0.05, 0.00),
    (18, "sun",      1.00, (1.04, 0.98, 0.92), 1.19, None,                 0.00, 1.08, 0.04, 0.70),
    (20, "twilight", 1.05, (0.94, 0.97, 1.08), 1.11, (0.35, 0.50, 0.79), 0.16, 1.12, 0.05, 0.00),
    (22, "night3",   1.04, (0.93, 0.97, 1.10), 1.08, None,                 0.00, 1.12, 0.03, 0.20),
]


def load(key: str, pan: float) -> np.ndarray:
    path = os.path.join(SRC, BASES[key])
    im = Image.open(path).convert("RGB")
    if im.size != (W, H):
        im = im.resize((W, H), Image.LANCZOS)
    # 同一素材在不同档位用轻微取景位移，避免完全相同的构图
    dx = int(W * 0.022 * pan)
    if dx:
        im = im.crop((dx, 0, W - dx, H)).resize((W, H), Image.LANCZOS)
    return np.asarray(im).astype(np.float32) / 255.0


def grade(key, exp, rgb, sat, sky, sky_k, contrast, dehaze, pan) -> Image.Image:
    a = load(key, pan)
    a = np.clip(a * exp, 0.0, 1.0)
    a = np.clip(a * np.array(rgb, dtype=np.float32)[None, None, :], 0.0, 1.0)
    # 去雾：压黑场再拉伸，去掉阴天照片那层灰白蒙版
    if dehaze > 0:
        a = np.clip((a - dehaze) / (1.0 - dehaze), 0.0, 1.0)
    a = np.clip((a - 0.5) * contrast + 0.5, 0.0, 1.0)
    # 饱和度：让草更绿、水更蓝，而不是灰成一片
    g = a.mean(axis=2, keepdims=True)
    a = np.clip(g + (a - g) * sat, 0.0, 1.0)
    # 天空渐变：只在画面上部叠一层淡蓝天光，保留原有云层纹理
    if sky_k > 0 and sky is not None:
        yy = np.linspace(1.0, 0.0, H, dtype=np.float32)[:, None, None]
        wgt = np.clip((yy - 0.45) / 0.55, 0.0, 1.0) ** 1.2 * sky_k
        a = a * (1.0 - wgt) + np.array(sky, dtype=np.float32)[None, None, :] * wgt
    out = Image.fromarray((np.clip(a, 0.0, 1.0) * 255).astype(np.uint8), "RGB")
    return out


def main():
    for f in BASES.values():
        if not os.path.exists(os.path.join(SRC, f)):
            sys.exit("缺少源图：" + f)

    made = []
    for (h, key, exp, rgb, sat, sky, sky_k, contrast, dehaze, pan) in PLAN:
        name = "scene-h%02d-sun.jpg" % h
        im = grade(key, exp, rgb, sat, sky, sky_k, contrast, dehaze, pan)
        im.save(os.path.join(SRC, name), quality=QUALITY, optimize=True)
        biomes = os.path.join(ROOT, "Resources", "biomes", "wetland")
        if os.path.isdir(biomes):
            im.save(os.path.join(biomes, name), quality=QUALITY, optimize=True)
        made.append(name)
        print("  %-22s ← %-10s" % (name, BASES[key]))

    # 联系表，仅供人工检查，输出到 /tmp（临时文件）
    tw, th = 400, 250
    sheet = Image.new("RGB", (tw * 4, th * 3), "white")
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 17)
    except OSError:
        font = ImageFont.load_default()
    for i, name in enumerate(made):
        im = Image.open(os.path.join(SRC, name)).convert("RGB")
        im.thumbnail((tw, th - 28))
        x, y = (i % 4) * tw, (i // 4) * th
        sheet.paste(im, (x + (tw - im.width) // 2, y))
        d.text((x + 8, y + th - 24), name, fill="black", font=font)
    sheet.save("/tmp/wd_sunny_sheet.jpg", quality=90)
    print("\n生成 %d 张，联系表 /tmp/wd_sunny_sheet.jpg" % len(made))


if __name__ == "__main__":
    main()
