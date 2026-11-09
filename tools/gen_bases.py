#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
生成高清「基底」照片：scene-clear / sunset / night / rain / snow.jpg

做法：Resources/photos/ 里当前被 git 记录的 1536×924 版本是经过裁切、且已获
用户确认的开阔构图（树梢 / 道路等遮挡在当年裁切时已去掉）。本脚本从这些已确认
的小图反推它在高清原图里的裁剪窗口（仅裁切、无调色，因此可逐像素对齐），再按
同一窗口裁出高清原图并统一放大到 3840×2310（与原图比例一致，= 1536/924），
从而既保留已确认的画面，又在大屏上清晰。

源图来自 tools/src_hires/（Wikimedia Commons 高清原图，沿用各自原许可与署名）。
用法： python3 tools/gen_bases.py
"""
import os
import sys
import json
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "tools", "src_hires")
DST = os.path.join(ROOT, "Resources", "photos")
TGT_W, TGT_H = 3840, 2310          # 与原 1536×924 同比例（≈1.6623）
ASPECT = TGT_W / TGT_H
QUALITY = 88

# 基底名 -> 高清原图文件名（必须与 git 里的 1536 版本是同一张照片）
SPECS = [
    ("scene-clear.jpg",  "芦苇连天 - Endless Wetland of Reeds - 2012.08 - panoramio.jpg"),
    ("scene-sunset.jpg", "Hengshui Lake, Hebei, China1.jpg"),
    ("scene-night.jpg",  "Frozen Pudasjarvi lake 20080308.jpg"),
    ("scene-rain.jpg",   "Goëngarijpsterpoelen (Frysk) Goaiïngarypster Puollen (d.j.b.) 21.jpg"),
    ("scene-snow.jpg",   "001 Zbiornik Kozłowa Góra, rzeka Brynica, Polska.jpg"),
]


def luma_key(im: Image.Image) -> list:
    g = im.convert("L").resize((192, 116), Image.BILINEAR)
    return list(g.getdata())


def match(O: Image.Image, x0, y0, cw, ch, Vk):
    sub = O.crop((x0, y0, x0 + cw, y0 + ch)).resize((192, 116), Image.BILINEAR)
    sk = list(sub.convert("L").getdata())
    return sum(abs(a - b) for a, b in zip(Vk, sk)) / len(Vk)


def recover_window(O: Image.Image, V: Image.Image):
    """在 O 中反推能最佳匹配 V(1536x924) 的同比例裁剪窗口 (cw, ch, x0, y0)。
    两阶段：先按高度逐档做粗 2D 搜索，再在最优高度附近做细 2D 搜索。"""
    Wo, Ho = O.size
    Vk = luma_key(V)
    ch_hi = min(Ho, int(Wo / ASPECT))
    ch_lo = max(240, int(Ho * 0.30))
    n_ch = 24
    best = None
    # 阶段一：粗搜（每档高度 6×6）
    for k in range(n_ch + 1):
        ch = ch_lo + (ch_hi - ch_lo) * k // n_ch
        cw = int(ch * ASPECT)
        if cw <= 0 or cw > Wo or ch > Ho:
            continue
        for xi in range(0, Wo - cw + 1, max(1, (Wo - cw) // 6)):
            for yi in range(0, Ho - ch + 1, max(1, (Ho - ch) // 6)):
                d = match(O, xi, yi, cw, ch, Vk)
                if best is None or d < best[0]:
                    best = (d, cw, ch, xi, yi)
    # 阶段二：在最优高度附近 ±3 档，每档细搜
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
                d = match(O, xi, yi, ncw, nch, Vk)
                if d < best[0]:
                    best = (d, ncw, nch, xi, yi)
    return best[1:]


def main():
    windows = {}
    for dst_name, src_name in SPECS:
        ref = os.path.join("/tmp", "wd_ref_" + dst_name)
        if not os.path.exists(ref):
            sys.exit("缺少 git 恢复的 1536 参考图：" + ref)
        O = Image.open(os.path.join(SRC, src_name)).convert("RGB")
        V = Image.open(ref).convert("RGB")
        cw, ch, x0, y0 = recover_window(O, V)
        crop = O.crop((x0, y0, x0 + cw, y0 + ch)).resize((TGT_W, TGT_H), Image.LANCZOS)
        crop.save(os.path.join(DST, dst_name), quality=QUALITY, optimize=True)
        windows[dst_name] = {"src": src_name, "window": [cw, ch, x0, y0],
                             "native_crop": [cw, ch], "out": [TGT_W, TGT_H]}
        print("  %-16s <- %s  window %sx%s @(%d,%d)"
              % (dst_name, src_name, cw, ch, x0, y0))
    json.dump(windows, open("/tmp/wd_windows.json", "w"), ensure_ascii=False, indent=2)
    print("已写出窗口到 /tmp/wd_windows.json")

    # 联系表
    import glob
    fs = ["scene-clear.jpg", "scene-sunset.jpg", "scene-night.jpg",
          "scene-rain.jpg", "scene-snow.jpg"]
    tw, th = 900, 545
    sheet = Image.new("RGB", (tw * 3, th * 2), "white")
    from PIL import ImageDraw, ImageFont
    d = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Unicode.ttf", 26)
    except OSError:
        font = ImageFont.load_default()
    for i, n in enumerate(fs):
        im = Image.open(os.path.join(DST, n)).convert("RGB")
        im.thumbnail((tw, th - 50))
        x, y = (i % 3) * tw, (i // 3) * th
        sheet.paste(im, (x + (tw - im.width) // 2, y))
        d.text((x + 14, y + th - 44), n, fill="black", font=font)
    sheet.save("/tmp/wd_bases_sheet.jpg", quality=92)
    print("联系表 /tmp/wd_bases_sheet.jpg")


if __name__ == "__main__":
    main()
