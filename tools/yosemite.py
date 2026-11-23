"""把优胜美地隧道观景台的延时照片转成穹顶与雾霭的场景数据（只用标准库）。

输入：照片先用 sips 转成 940x528 的 BMP（见 tools/yosemite.sh）。
输出：src/data/dome.lua —— 每行的游程编码，每个像素是「天空」或「某个深度层 × 某个亮度档」。
天空不存照片，由游戏按真实时间画；山体只存明暗，颜色由游戏按光来染。

用法：python3 tools/yosemite.py <bmp目录> [预览输出目录]
"""
import os
import struct
import sys

W, H = 176, 132
SRC_W, SRC_H = 940, 528   # 源图先用 sips 缩到这个尺寸
BASE = "yosemite_6K_fp_05.bmp"   # 晴朗白天的一帧，当作山体明暗的底子
DAY = ["yosemite_6K_fp_%02d.bmp" % i for i in (3, 4, 5, 6, 8)]  # 光线相近的白天帧，用来分天空和山
LEVELS = 6

ZONES = 2                        # 材质：0 岩石和雪，1 林子
TREELINE = [92, 98, 100, 100, 100, 100, 101, 102, 102]   # 每 22 列，谷底林子的上沿
GLOW_DEPTH = 22                  # 天际线以下多少行的岩石会被高山辉光照到

# 手描的天际线控制点（176x132 坐标）：酋长岩右缘 → 远处雪山 → 半穹顶 → 右边一路升高的山脊
SKY_POINTS = [(0, 10), (3, 11), (6, 14), (9, 18), (11, 22), (14, 26), (17, 29), (20, 32), (23, 37),
              (26, 42), (29, 44), (35, 42), (40, 40), (46, 40), (52, 41), (58, 43), (64, 45), (70, 47),
              (76, 46), (80, 42), (84, 39), (92, 38), (98, 39), (101, 42), (106, 41), (110, 37),
              (116, 35), (124, 32), (132, 30), (140, 28), (150, 27), (158, 25), (166, 23), (175, 21)]                # 每个深度层的亮度档数


def read_bmp(path):
    data = open(path, "rb").read()
    off = struct.unpack_from("<I", data, 10)[0]
    w, h = struct.unpack_from("<ii", data, 18)
    bpp = struct.unpack_from("<H", data, 28)[0]
    assert bpp == 24, "只支持 24 位 BMP"
    top_down = h < 0
    h = abs(h)
    row = (w * 3 + 3) // 4 * 4
    px = []
    for y in range(h):
        sy = y if top_down else h - 1 - y
        base = off + sy * row
        line = []
        for x in range(w):
            b, g, r = data[base + x * 3: base + x * 3 + 3]
            line.append((r, g, b))
        px.append(line)
    return px


# 裁切区域（在 940x528 的源图坐标里）：以半穹顶为中心，左边是酋长岩的侧影，右边是教堂岩，下面是山谷
CROP = (193, 179, 300, 225)   # x0, y0, 宽, 高（4:3）


def crop_down(px, crop=None):
    """切出 4:3 的一块，按面积平均缩到 176x132。"""
    x0, y0, cw, ch = crop or CROP
    out = []
    for y in range(H):
        ya, yb = y0 + y * ch // H, y0 + (y + 1) * ch // H
        line = []
        for x in range(W):
            xa, xb = x0 + x * cw // W, x0 + (x + 1) * cw // W
            acc, n = [0, 0, 0], 0
            for sy in range(ya, max(yb, ya + 1)):
                row = px[sy]
                for sx in range(xa, max(xb, xa + 1)):
                    p = row[sx]
                    acc[0] += p[0]; acc[1] += p[1]; acc[2] += p[2]
                    n += 1
            line.append((acc[0] // n, acc[1] // n, acc[2] // n))
        out.append(line)
    return out


def lum(p):
    return (p[0] * 30 + p[1] * 59 + p[2] * 11) // 100


def write_ppm(path, rows):
    with open(path, "wb") as f:
        f.write(b"P6\n%d %d\n255\n" % (W, H))
        for line in rows:
            for p in line:
                f.write(bytes(p))


def main():
    src = sys.argv[1]
    prev = sys.argv[2] if len(sys.argv) > 2 else None
    base = crop_down(read_bmp(os.path.join(src, BASE)))
    days = [crop_down(read_bmp(os.path.join(src, n))) for n in DAY]

    # 1. 天际线：照片里云、雪、背阴的岩石颜色太接近，自动分不清，所以先手描控制点，
    #    再在 ±3 像素里对齐到黎明那一帧（山是剪影）最明显的明暗边界。
    dawn = crop_down(read_bmp(os.path.join(src, "yosemite_6K_fp_01.bmp")))
    rough = []
    for x in range(W):
        for (xa, ya), (xb, yb) in zip(SKY_POINTS, SKY_POINTS[1:]):
            if xa <= x <= xb:
                rough.append(ya + (yb - ya) * (x - xa) // max(1, xb - xa))
                break
    skyline = []
    for x in range(W):
        best, best_y = -1, rough[x]
        for y in range(max(1, rough[x] - 3), min(H - 2, rough[x] + 4)):
            edge = (lum(dawn[y - 1][x]) - lum(dawn[y + 1][x])) + (lum(base[y - 1][x]) - lum(base[y + 1][x])) // 2
            edge -= abs(y - rough[x]) * 6  # 离手描的位置越远越不可信
            if edge > best:
                best, best_y = edge, y
        skyline.append(best_y)
    # 去掉孤立的尖刺
    sm = skyline[:]
    for x in range(1, W - 1):
        sm[x] = sorted(skyline[x - 1:x + 2])[1]
    skyline = sm

    # 2. 材质：林线以下是谷底的林子，以上是岩石和雪（照片里背阴的林子和岩石颜色太近，只能按林线分）
    def zone(x, y):
        i = min(x // 22, len(TREELINE) - 2)
        t = TREELINE[i] + (TREELINE[i + 1] - TREELINE[i]) * (x - i * 22) // 22
        return 1 if y >= t else 0

    # 3. 亮度：每层按自己的亮度分布均分成 LEVELS 档（每层都有完整的明暗）
    land = [(x, y) for y in range(H) for x in range(W) if y >= skyline[x]]
    cuts = {}
    for z in range(ZONES):
        ls = sorted(lum(base[y][x]) for (x, y) in land if zone(x, y) == z)
        cuts[z] = [ls[len(ls) * k // LEVELS] for k in range(1, LEVELS)]

    def level(z, p):
        l = lum(p)
        return sum(1 for c in cuts[z] if l >= c)

    # 4. 每个像素的类别：0 天空；1..N = 材质×档；N+1..2N 同上但会被高山辉光照到（天际线下方不远的岩石）
    cls = [[0] * W for _ in range(H)]
    acc = {}
    for (x, y) in land:
        z = zone(x, y)
        v = 1 + z * LEVELS + level(z, base[y][x])
        if z == 0 and y - skyline[x] < GLOW_DEPTH:
            v += ZONES * LEVELS
        cls[y][x] = v
        a = acc.setdefault(v, [0, 0, 0, 0])
        p = base[y][x]
        a[0] += p[0]; a[1] += p[1]; a[2] += p[2]; a[3] += 1
    # 横向去掉孤立的单个像素（夹在两个相同类别中间），画面更干净，游程也少
    for y in range(H):
        row = cls[y]
        for x in range(1, W - 1):
            if row[x - 1] == row[x + 1] != row[x] and row[x] != 0 and row[x - 1] != 0:
                row[x] = row[x - 1]
    # 每类的颜色 = 照片里这一类像素的平均色
    pal = []
    for v in range(1, 2 * ZONES * LEVELS + 1):
        a = acc.get(v)
        if not a:
            a = acc.get(v - ZONES * LEVELS) if v > ZONES * LEVELS else None
        pal.append((a[0] // a[3], a[1] // a[3], a[2] // a[3]) if a else (0, 0, 0))

    # 5. 游程编码：每段两个字符，类别 chr(48+v)，长度 chr(48+n)（n ≤ 70）
    rows, runs = [], 0
    for y in range(H):
        out, x = [], 0
        while x < W:
            v = cls[y][x]
            n = 1
            while x + n < W and cls[y][x + n] == v and n < 70:
                n += 1
            out.append(chr(48 + v) + chr(48 + n))
            runs += 1
            x += n
        rows.append("".join(out))
    body = "\n".join(rows)
    assert "]==]" not in body
    dst = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "data", "dome.lua")
    os.makedirs(os.path.dirname(dst), exist_ok=True)
    with open(dst, "w", encoding="utf-8") as f:
        f.write("-- 由 tools/yosemite.py 从优胜美地隧道观景台的照片生成，不要手改\n")
        f.write("-- rows：每行的游程，两字符一段：类别 chr(48+v)、长度 chr(48+n)。v=0 天空，1..12 材质×档，13..24 会被辉光照到\n")
        f.write("local SCENE = {\n  levels = %d,\n" % LEVELS)
        f.write("  skyline = [==[%s]==],\n" % "".join(chr(48 + v) for v in skyline))  # 长括号：里面可能有反斜杠
        f.write("  pal = { %s },\n" % ", ".join("{ %d, %d, %d }" % p for p in pal))
        f.write("  rows = [==[\n%s\n]==],\n}\n" % body)
    print("runs:", runs, "->", dst)

    if prev:
        os.makedirs(prev, exist_ok=True)
        write_ppm(os.path.join(prev, "base.ppm"), base)
        flat = [[(40, 90, 200) if cls[y][x] == 0 else pal[cls[y][x] - 1] for x in range(W)] for y in range(H)]
        write_ppm(os.path.join(prev, "scene.ppm"), flat)


if __name__ == "__main__":
    main()
