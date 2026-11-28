#!/usr/bin/env python3
"""生成 README 顶部的品牌动图（拾光 Luma）。

画面上不写文字，只留光：
左侧，过去的光尘被一点点拾起，向中间汇拢；
中间，汇成一束；
右侧，一粒光被投递出去，划向未来。

用法：python3 Tools/design/brand_hero_gif.py
产物：docs/design/assets/brand-hero.gif（Markdown 里可直接播放）
"""

import math
import os
import random

from PIL import Image, ImageDraw, ImageFilter, ImageFont

W, H = 960, 560
FRAMES = 64
FRAME_MS = 50

CJK = "/System/Library/Fonts/Hiragino Sans GB.ttc"


def font(path, size, index=0):
    try:
        return ImageFont.truetype(path, size, index=index)
    except OSError:
        return ImageFont.truetype(path, size)


TITLE_FONT = font(CJK, 118, index=2)

# 品牌色
CORAL = (255, 143, 122)
AMBER = (255, 196, 107)
PINK = (255, 122, 199)
VIOLET = (168, 140, 255)
CYAN = (94, 217, 255)
MINT = (125, 247, 191)

random.seed(20261125)


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def gradient_row(stops, width):
    """横向多段渐变。"""
    img = Image.new("RGB", (width, 1))
    px = img.load()
    for x in range(width):
        t = x / max(1, width - 1) * (len(stops) - 1)
        i = min(int(t), len(stops) - 2)
        px[x, 0] = lerp(stops[i], stops[i + 1], t - i)
    return img


def add_glow(base, color, center, radius, strength):
    """在整张画布上叠一团柔光；椭圆完全落在画布内，边缘自然衰减，不留方框接缝。"""
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(mask)
    cx, cy = center
    d.ellipse([cx - radius, cy - radius, cx + radius, cy + radius], fill=255)
    mask = mask.filter(ImageFilter.GaussianBlur(radius * 0.62))
    mask = mask.point(lambda v: int(v * strength))
    tint = Image.new("RGB", (W, H), color)
    base.paste(tint, (0, 0), mask)


def blit_orb(img, x, y, radius, color, alpha, halo=2.8, blur=1.6):
    """一小团带柔光的光点；只处理局部小块，避免整幅高斯模糊。"""
    if alpha <= 0 or radius <= 0:
        return
    pad = int(radius * halo * 2 + 6)
    size = pad * 2
    glow = Image.new("L", (size, size), 0)
    gd = ImageDraw.Draw(glow)
    gd.ellipse([pad - radius * halo, pad - radius * halo,
                pad + radius * halo, pad + radius * halo], fill=int(alpha * 0.5))
    glow = glow.filter(ImageFilter.GaussianBlur(radius * blur))
    img.paste(Image.new("RGB", (size, size), color), (int(x) - pad, int(y) - pad), glow)
    cd = ImageDraw.Draw(img)
    r = radius * 0.55
    cd.ellipse([x - r, y - r, x + r, y + r], fill=color)


def blit_trail(img, points, color, alpha, width=2.0, blur=2.4):
    """一条由暗到亮、末端收细的光迹；局部绘制，尾部自然融进夜色。"""
    if alpha <= 0 or len(points) < 2:
        return
    pad = int(width * 3 + blur * 4 + 8)
    xs = [p[0] for p in points]
    ys = [p[1] for p in points]
    x0 = int(min(xs)) - pad
    y0 = int(min(ys)) - pad
    w = int(max(xs) - min(xs)) + pad * 2
    h = int(max(ys) - min(ys)) + pad * 2
    if w <= 0 or h <= 0:
        return
    mask = Image.new("L", (w, h), 0)
    d = ImageDraw.Draw(mask)
    n = len(points)
    for i in range(n - 1):
        a = int(alpha * (i / (n - 1)) ** 1.6)
        d.line([(points[i][0] - x0, points[i][1] - y0),
                (points[i + 1][0] - x0, points[i + 1][1] - y0)], fill=a, width=int(width))
    mask = mask.filter(ImageFilter.GaussianBlur(blur))
    img.paste(Image.new("RGB", (w, h), color), (x0, y0), mask)


def build_base():
    """深空底：上紫下青、几团品牌色光晕、四角压暗。"""
    base = Image.new("RGB", (W, H))
    draw = ImageDraw.Draw(base)
    top = (32, 22, 52)
    bottom = (7, 20, 26)
    for y in range(H):
        draw.line([(0, y), (W, y)], fill=lerp(top, bottom, (y / H) ** 0.92))

    # 左下的旧日暖光，右上的未来冷光
    add_glow(base, (120, 60, 150), (W * 0.20, H * 0.24), W * 0.34, 0.30)
    add_glow(base, (140, 84, 46), (W * 0.74, H * 0.30), W * 0.30, 0.20)
    add_glow(base, (24, 96, 128), (W * 0.52, H * 0.82), W * 0.36, 0.22)
    add_glow(base, (150, 84, 40), (W * 0.08, H * 0.78), W * 0.22, 0.16)
    add_glow(base, (26, 120, 150), (W * 0.90, H * 0.60), W * 0.20, 0.16)

    # 暗角
    vignette = Image.new("L", (W, H), 0)
    vd = ImageDraw.Draw(vignette)
    vd.ellipse([-W * 0.18, -H * 0.22, W * 1.18, H * 1.22], fill=255)
    vignette = vignette.filter(ImageFilter.GaussianBlur(90))
    shade = Image.new("RGB", (W, H), (0, 0, 0))
    base = Image.composite(base, Image.blend(base, shade, 0.55), vignette)
    return base


STARS = [
    (
        random.uniform(10, W - 10),
        random.uniform(10, H * 0.78),
        random.choice([1.4, 1.7, 2.0, 2.4, 2.9]),
        random.choice([AMBER, PINK, VIOLET, CYAN, MINT, (230, 233, 240)]),
        random.uniform(0, math.tau),
        random.choice([1.0, 2.0]),
    )
    for _ in range(96)
]


def mote_color(x):
    """左侧偏暖，右侧偏冷：过去与未来各有一侧的光。"""
    if x < W * 0.40:
        return random.choice([AMBER, (255, 170, 120), CORAL])
    if x > W * 0.62:
        return random.choice([VIOLET, CYAN, MINT])
    return random.choice([PINK, VIOLET])


MOTES = [
    (
        x := random.uniform(20, W - 20),
        random.uniform(H * 0.12, H * 0.95),
        random.choice([2.0, 2.6, 3.2]),
        mote_color(x),
        random.uniform(4, 16),
        random.uniform(0, math.tau),
    )
    for _ in range(34)
]

TITLE_TOP = 88
TITLE_CANVAS_H = 260


def build_title_mask():
    """「拾光」的文字遮罩 + 外发光。"""
    mask = Image.new("L", (W, TITLE_CANVAS_H), 0)
    d = ImageDraw.Draw(mask)
    d.text((W / 2, 124), "拾光", font=TITLE_FONT, fill=255, anchor="mm")
    return mask


def build_title_gradient(mask):
    """渐变贴着文字实际宽度铺：左暖右冷，两个字各自跨到不同的色相。"""
    x0, _, x1, _ = mask.getbbox()
    pad = 24
    row = gradient_row([AMBER, CORAL, PINK, VIOLET, CYAN], max(1, x1 - x0 + pad * 2))
    grad = Image.new("RGB", (W, TITLE_CANVAS_H))
    for y in range(TITLE_CANVAS_H):
        grad.paste(row, (x0 - pad, y))
    return grad


TITLE_MASK = build_title_mask()
TITLE_GRAD = build_title_gradient(TITLE_MASK)
TITLE_GLOW = TITLE_MASK.filter(ImageFilter.GaussianBlur(26))

FOCUS_NX = 0.5
CAST_END = (W * 0.895, H * 0.235)


def wave_y(x, t):
    """历史 → 此刻 → 未来 的光线：左侧沉、中间汇聚、右侧缓缓抬升。"""
    nx = x / W
    base = H * 0.815
    lift = -22 * max(0.0, nx - 0.5) / 0.5
    bend = 14 * math.sin(nx * math.pi * 2.1 + 0.4)
    dip = -26 * math.exp(-((nx - FOCUS_NX) ** 2) / 0.012)
    flow = 3.0 * math.sin(nx * 12 - t * math.tau)
    return base + lift + bend + dip + flow


def draw_wave(img, t):
    glow = Image.new("RGB", (W, H), (0, 0, 0))
    glow_mask = Image.new("L", (W, H), 0)
    line = Image.new("RGB", (W, H), (0, 0, 0))
    line_mask = Image.new("L", (W, H), 0)
    ld = ImageDraw.Draw(line)
    gm = ImageDraw.Draw(glow_mask)
    lm = ImageDraw.Draw(line_mask)

    points = [(x, wave_y(x, t)) for x in range(-10, W + 12, 4)]
    for i in range(len(points) - 1):
        nx = min(1.0, max(0.0, points[i][0] / W))
        # 两端渐隐：左侧从旧光里浮出，右侧散进未来
        fade = min(1.0, nx / 0.06, (1.0 - nx) / 0.12)
        if fade <= 0:
            continue
        color = lerp(AMBER, PINK, min(1, nx * 2)) if nx < 0.5 else lerp(PINK, CYAN, (nx - 0.5) * 2)
        ld.line([points[i], points[i + 1]], fill=color, width=2)
        gm.line([points[i], points[i + 1]], fill=int(150 * fade), width=9)
        lm.line([points[i], points[i + 1]], fill=int(210 * fade), width=2)

    glow_mask = glow_mask.filter(ImageFilter.GaussianBlur(9))
    img.paste(glow, (0, 0), glow_mask)
    img.paste(line, (0, 0), line_mask)

    # 此刻：汇聚处的一呼一吸
    fx = FOCUS_NX * W
    fy = wave_y(fx, t)
    pulse = 0.5 + 0.5 * math.sin(t * math.tau * 2)
    blit_orb(img, fx, fy, 7.5 + 2.0 * pulse, (255, 238, 242), int(105 + 40 * pulse), halo=3.6)

    # 沿光线游走的光点：被拾起的一束光
    for offset, radius, color in [(0.0, 4.6, (255, 246, 226)), (-0.06, 2.4, AMBER), (-0.13, 1.9, PINK)]:
        nx = (t + offset) % 1.0
        x = nx * W
        y = wave_y(x, t)
        fade = min(1.0, nx / 0.04, (1.0 - nx) / 0.08)
        blit_orb(img, x, y, radius, color, int(180 * fade), halo=3.4)


def draw_stars(img, t):
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(layer)
    m = ImageDraw.Draw(mask)
    for x, y, r, color, phase, speed in STARS:
        twinkle = 0.5 + 0.5 * math.sin(t * math.tau * speed + phase)
        alpha = int(70 + 150 * twinkle)
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)
        m.ellipse([x - r, y - r, x + r, y + r], fill=alpha)
    mask = mask.filter(ImageFilter.GaussianBlur(0.6))
    img.paste(layer, (0, 0), mask)


def draw_motes(img, t):
    """缓慢漂浮的微尘：不写时间，只用冷暖暗示哪一侧是过去、哪一侧是未来。"""
    layer = Image.new("RGB", (W, H), (0, 0, 0))
    mask = Image.new("L", (W, H), 0)
    d = ImageDraw.Draw(layer)
    m = ImageDraw.Draw(mask)
    for x0, y0, r, color, amp, phase in MOTES:
        x = x0 + 10 * math.sin(t * math.tau + phase)
        y = y0 + amp * math.sin(t * math.tau + phase * 1.7)
        alpha = int(70 + 100 * (0.5 + 0.5 * math.sin(t * math.tau + phase * 2.1)))
        d.ellipse([x - r, y - r, x + r, y + r], fill=color)
        m.ellipse([x - r, y - r, x + r, y + r], fill=alpha)
    mask = mask.filter(ImageFilter.GaussianBlur(1.4))
    img.paste(layer, (0, 0), mask)


GATHER = [
    (
        random.uniform(0.0, 0.30) * W,
        random.uniform(H * 0.90, H * 1.04),
        random.random(),
        random.choice([1.0, 2.0]),
        random.uniform(1.6, 3.0),
        random.choice([AMBER, CORAL, (255, 170, 120), PINK]),
    )
    for _ in range(24)
]


def bezier(p0, p1, p2, u):
    v = 1 - u
    return (v * v * p0[0] + 2 * v * u * p1[0] + u * u * p2[0],
            v * v * p0[1] + 2 * v * u * p1[1] + u * u * p2[1])


def draw_gather(img, t):
    """过去的光尘从画面左下浮起，被一点点拾到「此刻」。"""
    fx = FOCUS_NX * W
    fy = wave_y(fx, t)
    for x0, y0, phase, speed, radius, color in GATHER:
        p = (t * speed + phase) % 1.0
        ctrl = (x0 + (fx - x0) * 0.45, y0 - 170)
        end = (fx + 12 * math.sin(phase * 7), fy + 9 * math.cos(phase * 5))
        fade = math.sin(math.pi * p) ** 1.3
        if fade <= 0.01:
            continue
        tail = [bezier((x0, y0), ctrl, end, max(0.0, p - 0.26 * (1 - k / 11)))
                for k in range(12)]
        blit_trail(img, tail, color, int(100 * fade), width=2.4, blur=2.4)
        x, y = bezier((x0, y0), ctrl, end, p)
        blit_orb(img, x, y, radius, color, int(140 * fade), halo=3.0, blur=1.3)


def cast_u(p):
    return min(1.0, max(0.0, (p - 0.10) / 0.58))


def cast_point(t):
    nx = 0.66
    start = (nx * W, wave_y(nx * W, t))
    c1 = (0.74 * W, wave_y(0.74 * W, t) - 80)
    c2 = (0.86 * W, H * 0.46)
    return start, c1, c2


def draw_cast(img, t):
    """一粒光从「此刻」的线上被投递出去，划向右上方的未来。"""
    p = (t + 0.08) % 1.0
    start, c1, c2 = cast_point(t)
    u = cast_u(p)
    if u <= 0:
        return
    end = CAST_END

    # 轨迹：从起点到落点的三次贝塞尔，带一条渐弱的尾迹
    def at(v):
        v0 = 1 - v
        return (v0 ** 3 * start[0] + 3 * v0 * v0 * v * c1[0] + 3 * v0 * v * v * c2[0] + v ** 3 * end[0],
                v0 ** 3 * start[1] + 3 * v0 * v0 * v * c1[1] + 3 * v0 * v * v * c2[1] + v ** 3 * end[1])

    tail_fade = 1.0 if p < 0.95 else max(0.0, (1.0 - p) / 0.05)
    tail = [at(max(0.0, u - 0.36 * (1 - k / 23))) for k in range(24)]
    blit_trail(img, tail, (255, 214, 228), int(120 * tail_fade), width=3.0, blur=2.6)

    x, y = at(u)
    blit_orb(img, x, y, 4.2, (255, 244, 236), int(235 * tail_fade), halo=4.0, blur=1.5)

    # 起手处的一点回响：像把光从掌心送出去
    if u < 0.2:
        q = u / 0.2
        ring = 4 + 10 * q
        ring_img = Image.new("L", (W, H), 0)
        rd = ImageDraw.Draw(ring_img)
        rd.ellipse([start[0] - ring, start[1] - ring, start[0] + ring, start[1] + ring],
                   outline=int(90 * (1 - q)), width=2)
        ring_img = ring_img.filter(ImageFilter.GaussianBlur(2.0))
        img.paste(Image.new("RGB", (W, H), (255, 214, 196)), (0, 0), ring_img)

    # 抵达未来：轻轻散开的一圈光
    if u >= 1.0 and p < 0.95:
        q = min(1.0, max(0.0, (p - 0.68) / 0.24))
        ring = 6 + 34 * q
        ring_img = Image.new("L", (W, H), 0)
        rd = ImageDraw.Draw(ring_img)
        rd.ellipse([end[0] - ring, end[1] - ring, end[0] + ring, end[1] + ring],
                   outline=int(120 * (1 - q)), width=2)
        ring_img = ring_img.filter(ImageFilter.GaussianBlur(2.2))
        img.paste(Image.new("RGB", (W, H), (190, 232, 255)), (0, 0), ring_img)
        blit_orb(img, end[0], end[1], 3.0, (225, 246, 255), int(190 * (1 - q)), halo=4.2)


def build_frame(base, t):
    img = base.copy()

    # 标题背后的呼吸光
    pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(t * math.tau))
    aura = Image.new("RGB", (W, TITLE_CANVAS_H), (255, 150, 180))
    aura_mask = TITLE_GLOW.point(lambda v: int(v * (0.22 + 0.16 * pulse)))
    img.paste(aura, (0, TITLE_TOP - 6), aura_mask)

    draw_stars(img, t)
    draw_motes(img, t)
    draw_gather(img, t)
    draw_wave(img, t)
    draw_cast(img, t)

    float_y = int(4 * math.sin(t * math.tau))
    img.paste(TITLE_GRAD, (0, TITLE_TOP + float_y), TITLE_MASK)
    return img


def main():
    base = build_base()
    frames = [build_frame(base, index / FRAMES) for index in range(FRAMES)]

    os.makedirs("docs/design/assets", exist_ok=True)
    palette_source = frames[0].quantize(colors=192, method=Image.MEDIANCUT, dither=Image.NONE)
    quantized = [f.quantize(palette=palette_source, dither=Image.NONE) for f in frames]
    out = "docs/design/assets/brand-hero.gif"
    quantized[0].save(out, save_all=True, append_images=quantized[1:],
                      duration=FRAME_MS, loop=0, optimize=True, disposal=2)
    frames[24].save("docs/design/assets/brand-hero.png")
    print("wrote", out, os.path.getsize(out) // 1024, "KB")


if __name__ == "__main__":
    main()
