#!/usr/bin/env python3
"""把 HYG 星表与 Stellarium 星座线压成 Sources/StarCatalog.swift。

数据来源：
  HYG Database v2 hygfull.csv.gz  (Hipparcos / Yale BSC, J2000)
    https://github.com/astronexus/HYG-Database/blob/main/hyg/v2/hygfull.csv.gz
  Stellarium modern skyculture index.json (88 IAU 星座连线, HIP 编号)
    https://github.com/Stellarium/stellarium/blob/master/skycultures/modern/index.json

用法：python3 tools/gen_catalog.py <hygfull.csv> <index.json> [输出.swift]
两份原始数据只用于离线生成，App 运行时不联网、不需要它们。
"""
import base64
import csv
import json
import os
import struct
import sys
import textwrap

# IAU 三字母缩写 → 中文名
CON_ZH = {
    "And": "仙女座", "Ant": "唧筒座", "Aps": "天燕座", "Aqr": "宝瓶座", "Aql": "天鹰座",
    "Ara": "天坛座", "Ari": "白羊座", "Aur": "御夫座", "Boo": "牧夫座", "Cae": "雕具座",
    "Cam": "鹿豹座", "Cnc": "巨蟹座", "CVn": "猎犬座", "CMa": "大犬座", "CMi": "小犬座",
    "Cap": "摩羯座", "Car": "船底座", "Cas": "仙后座", "Cen": "半人马座", "Cep": "仙王座",
    "Cet": "鲸鱼座", "Cha": "蝘蜓座", "Cir": "圆规座", "Col": "天鸽座", "Com": "后发座",
    "CrA": "南冕座", "CrB": "北冕座", "Crv": "乌鸦座", "Crt": "巨爵座", "Cru": "南十字座",
    "Cyg": "天鹅座", "Del": "海豚座", "Dor": "剑鱼座", "Dra": "天龙座", "Equ": "小马座",
    "Eri": "波江座", "For": "天炉座", "Gem": "双子座", "Gru": "天鹤座", "Her": "武仙座",
    "Hor": "时钟座", "Hya": "长蛇座", "Hyi": "水蛇座", "Ind": "印第安座", "Lac": "蝎虎座",
    "Leo": "狮子座", "LMi": "小狮座", "Lep": "天兔座", "Lib": "天秤座", "Lup": "豺狼座",
    "Lyn": "天猫座", "Lyr": "天琴座", "Men": "山案座", "Mic": "显微镜座", "Mon": "麒麟座",
    "Mus": "苍蝇座", "Nor": "矩尺座", "Oct": "南极座", "Oph": "蛇夫座", "Ori": "猎户座",
    "Pav": "孔雀座", "Peg": "飞马座", "Per": "英仙座", "Phe": "凤凰座", "Pic": "绘架座",
    "Psc": "双鱼座", "PsA": "南鱼座", "Pup": "船尾座", "Pyx": "罗盘座", "Ret": "网罟座",
    "Sge": "天箭座", "Sgr": "人马座", "Sco": "天蝎座", "Scl": "玉夫座", "Sct": "盾牌座",
    "Ser": "巨蛇座", "Sex": "六分仪座", "Tau": "金牛座", "Tel": "望远镜座", "Tri": "三角座",
    "TrA": "南三角座", "Tuc": "杜鹃座", "UMa": "大熊座", "UMi": "小熊座", "Vel": "船帆座",
    "Vir": "室女座", "Vol": "飞鱼座", "Vul": "狐狸座",
}

# 常见亮星专名（HYG ProperName）→ 中文名
STAR_ZH = {
    "Sirius": "天狼", "Canopus": "老人", "Rigil Kent": "南门二", "Arcturus": "大角",
    "Vega": "织女一", "Capella": "五车二", "Rigel": "参宿七", "Procyon": "南河三",
    "Achernar": "水委一", "Betelgeuse": "参宿四", "Hadar": "马腹一", "Altair": "河鼓二",
    "Acrux": "十字架二", "Aldebaran": "毕宿五", "Antares": "心宿二", "Spica": "角宿一",
    "Pollux": "北河三", "Fomalhaut": "北落师门", "Deneb": "天津四", "Mimosa": "十字架三",
    "Regulus": "轩辕十四", "Adhara": "弧矢七", "Castor": "北河二", "Gacrux": "十字架一",
    "Shaula": "尾宿八", "Bellatrix": "参宿五", "Elnath": "五车五", "Miaplacidus": "南船五",
    "Alnilam": "参宿二", "Alnair": "鹤一", "Alnitak": "参宿一", "Alioth": "玉衡",
    "Dubhe": "天枢", "Wezen": "弧矢一", "Alkaid": "摇光", "Sargas": "尾宿五",
    "Avior": "海石一", "Menkalinan": "五车三", "Atria": "三角形三", "Alhena": "井宿三",
    "Peacock": "孔雀十一", "Alsephina": "弧矢增二十二", "Mirzam": "军市一", "Alphard": "星宿一",
    "Polaris": "北极星", "Hamal": "娄宿三", "Algieba": "轩辕十二", "Diphda": "土司空",
    "Nunki": "斗宿四", "Menkent": "库楼三", "Alpheratz": "壁宿二", "Mirach": "奎宿九",
    "Saiph": "参宿六", "Kochab": "北极二", "Rasalhague": "侯", "Algieba": "轩辕十二",
    "Algol": "大陵五", "Almach": "天大将军一", "Denebola": "五帝座一", "Muhlifain": "库楼七",
    "Cursa": "玉井三", "Mintaka": "参宿三", "Sadr": "天津一", "Eltanin": "天棓四",
    "Schedar": "王良四", "Caph": "王良一", "Alcyone": "昴宿六", "Markab": "室宿一",
    "Scheat": "室宿二", "Algenib": "壁宿一", "Zubenelgenubi": "氐宿一", "Albireo": "辇道增七",
    "Mizar": "开阳", "Merak": "天璇", "Phecda": "天玑", "Megrez": "天权", "Thuban": "右枢",
    "Vindemiatrix": "东次将", "Porrima": "东上相", "Algorab": "轸宿三", "Gienah": "轸宿一",
    "Zubeneschamali": "氐宿四", "Unukalhai": "天市右垣七", "Kaus Australis": "箕宿三",
    "Ankaa": "火鸟六", "Acamar": "天园六", "Zaurak": "天苑四", "Mirfak": "天船三",
    "Naos": "弧矢增二十二", "Suhail": "天记", "Aspidiske": "海石二", "Alphard": "星宿一",
}


def con_of(bayer):
    """'21Alp And' / 'Kap1Scl' / '29    Psc' → 'And' / 'Scl' / 'Psc'"""
    if not bayer:
        return None
    s = bayer.strip()
    if len(s) >= 3 and " " in s:
        tail = s.split()[-1]
        if len(tail) == 3 and tail[0].isupper():
            return tail
    tail3 = s[-3:]
    if len(tail3) == 3 and tail3[0].isupper() and tail3[1:].islower():
        return tail3
    return None


def b64_lines(data, width=100):
    s = base64.b64encode(data).decode("ascii")
    return ["        \"%s\"," % chunk for chunk in textwrap.wrap(s, width)]


def main():
    csv_path = sys.argv[1]
    idx_path = sys.argv[2]
    out_path = sys.argv[3] if len(sys.argv) > 3 else os.path.join(
        os.path.dirname(__file__), "..", "Sources", "StarCatalog.swift")

    # 星座缩写表：按字母序固定，索引写进每颗星
    doc = json.load(open(idx_path))
    cons = sorted({c["id"].split()[-1] for c in doc["constellations"]})
    con_index = {c: i for i, c in enumerate(cons)}

    hip2con = {}
    hip_pairs = []
    for c in doc["constellations"]:
        abbr = c["id"].split()[-1]
        for chain in c.get("lines", []):
            hips = [int(h) for h in chain]
            for h in hips:
                hip2con[h] = abbr
            for a, b in zip(hips, hips[1:]):
                hip_pairs.append((a, b, abbr))

    rows = []
    for r in csv.DictReader(open(csv_path)):
        try:
            mag = float(r["Mag"])
        except (ValueError, KeyError):
            continue
        if mag > 6.5:            # 6.5 等：肉眼极限，暗于它的交给银河雾带
            continue
        try:
            ra_h = float(r["RA"])
            dec = float(r["Dec"])
            bv = float(r["ColorIndex"] or 0.30)
        except ValueError:
            continue
        hip = int(float(r["Hip"])) if r["Hip"] else 0
        abbr = hip2con.get(hip) or con_of(r["BayerFlamsteed"])
        con = con_index.get(abbr, 255) if abbr else 255
        rows.append((mag, ra_h, dec, bv, hip, con, r["ProperName"].strip()))

    rows.sort(key=lambda x: x[0])   # 亮星在前：绘制时倒序，标注时正序
    hip2idx = {}
    for i, row in enumerate(rows):
        if row[4]:
            hip2idx[row[4]] = i

    buf = bytearray()
    for mag, ra_h, dec, bv, hip, con, _ in rows:
        ra16 = round(min(24.0, max(0.0, ra_h)) / 24.0 * 65535)
        dec16 = round(max(-90.0, min(90.0, dec)) / 90.0 * 32767)
        mag8 = round(max(-12.0, min(12.0, mag)) * 10)
        bv8 = max(0, min(255, round((max(-0.5, min(2.0, bv)) + 0.5) * 100)))
        buf += struct.pack("<HhbBIBB", ra16, dec16, mag8, bv8, hip, con, 0)

    seen = set()
    lines = bytearray()
    for a, b, abbr in hip_pairs:
        ia, ib = hip2idx.get(a), hip2idx.get(b)
        if ia is None or ib is None or ia == ib:
            continue
        key = (min(ia, ib), max(ia, ib))
        if key in seen:
            continue
        seen.add(key)
        lines += struct.pack("<HH", ia, ib)

    names = {}
    for i, row in enumerate(rows):
        zh = STAR_ZH.get(row[6])
        if zh:
            names[row[4]] = zh

    zh_con = ",\n".join('        "%s": "%s"' % (c, CON_ZH.get(c, c + "座")) for c in cons)
    zh_star = ",\n".join('        %d: "%s"' % (k, v) for k, v in sorted(names.items()))
    star_b64 = "\n".join(b64_lines(bytes(buf)))
    line_b64 = "\n".join(b64_lines(bytes(lines)))

    swift = '''// 自动生成，请勿手改。来源与再生成方式见 tools/gen_catalog.py
// HYG Database v2（依巴谷 / Yale BSC，J2000）+ Stellarium modern 星座连线。
// %(nstar)d 颗视星等 ≤ 6.5 的恒星，%(nline)d 条星座连线。
import Foundation

struct CatalogStar {
    let ra: Double      // J2000 赤经，弧度
    let dec: Double     // J2000 赤纬，弧度
    let mag: Double     // 视星等
    let bv: Double      // B-V 色指数
    let hip: UInt32
    let con: UInt8      // 星座索引，255 = 未归类
}

enum StarCatalog {
    static let constellationNames: [String: String] = [
%(zh_con)s
    ]

    /// HIP → 中文星名（常见亮星）
    static let starNames: [UInt32: String] = [
%(zh_star)s
    ]

    private static let starBase64 = String(
        [
%(star_b64)s
        ].joined())

    private static let lineBase64 = String(
        [
%(line_b64)s
        ].joined())

    static let constellations: [String] = [%(cons)s]

    static let stars: [CatalogStar] = {
        guard let d = Data(base64Encoded: starBase64) else { return [] }
        let n = d.count / 12
        var out: [CatalogStar] = []
        out.reserveCapacity(n)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let p = raw.baseAddress! + i * 12
                let ra16 = p.loadUnaligned(fromByteOffset: 0, as: UInt16.self)
                let dec16 = p.loadUnaligned(fromByteOffset: 2, as: Int16.self)
                let mag8 = p.loadUnaligned(fromByteOffset: 4, as: Int8.self)
                let bv8 = p.loadUnaligned(fromByteOffset: 5, as: UInt8.self)
                let hip = p.loadUnaligned(fromByteOffset: 6, as: UInt32.self)
                let con = p.loadUnaligned(fromByteOffset: 10, as: UInt8.self)
                out.append(CatalogStar(
                    ra: Double(ra16) / 65535.0 * 24.0 * .pi / 12.0,
                    dec: Double(dec16) / 32767.0 * 90.0 * .pi / 180.0,
                    mag: Double(mag8) / 10.0,
                    bv: Double(bv8) / 100.0 - 0.5,
                    hip: hip, con: con))
            }
        }
        return out
    }()

    /// 星座连线，元素是 stars 的下标
    static let lines: [(Int, Int)] = {
        guard let d = Data(base64Encoded: lineBase64) else { return [] }
        let n = d.count / 4
        var out: [(Int, Int)] = []
        out.reserveCapacity(n)
        d.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for i in 0..<n {
                let a = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt16.self)
                let b = raw.loadUnaligned(fromByteOffset: i * 4 + 2, as: UInt16.self)
                out.append((Int(a), Int(b)))
            }
        }
        return out
    }()
}
''' % {
        "nstar": len(rows), "nline": len(lines) // 4,
        "zh_con": zh_con, "zh_star": zh_star,
        "star_b64": star_b64, "line_b64": line_b64,
        "cons": ", ".join('"%s"' % c for c in cons),
    }
    with open(out_path, "w") as f:
        f.write(swift)
    print("wrote %s: %d stars, %d lines, %d constellations, %d names, %d bytes"
          % (out_path, len(rows), len(lines) // 4, len(cons), len(names), len(swift)))


if __name__ == "__main__":
    main()
