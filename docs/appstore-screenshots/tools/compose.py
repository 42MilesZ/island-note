#!/usr/bin/env python3
"""Compose Island Note Mac App Store screenshots (2880x1800) from real UI captures.

Units are points; the canvas is rendered at 2x. Captures come from the screenshot
harness (window PNGs at 2x + JSON window frames in Cocoa screen coordinates).
"""
import json, math, os, random, sys, io
import skia
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
A = lambda *p: os.path.join(ROOT, 'assets', *p)
CAP = lambda *p: os.path.join(ROOT, 'out', *p)
W, H, SCALE = 1440, 900, 2
SCREEN_W, SCREEN_H = 1512.0, 982.0      # MacBook Pro 14" default "looks like"
MENU_H = 33.0                            # menu bar / notch-row height on this display
NOTCH_W, NOTCH_H = 185.0, 32.0           # from NSScreen auxiliaryTop areas / safeAreaInsets

BG = skia.Color(244, 242, 236)           # zhuhanyu.me light paper
INK = (28, 27, 23)
INK2 = skia.Color(111, 107, 98)

# ---------------------------------------------------------------- fonts
def tag(s): return (ord(s[0]) << 24) | (ord(s[1]) << 16) | (ord(s[2]) << 8) | ord(s[3])
_tf_cache = {}
def sf(weight, size, rounded=False):
    """Static instances cut from SFNS.ttf with fontTools (skia-python ignores variation clones)."""
    if weight >= 600 and size >= 30: name = 'display-semibold'
    elif weight >= 650: name = 'text-bold'
    elif size >= 15 and size < 18: name = 'icon'
    elif size >= 18: name = 'text-regular'
    else: name = 'text-medium'
    key = ('sf', name)
    if key not in _tf_cache:
        _tf_cache[key] = skia.Typeface.MakeFromFile(A('inst', f'sf-{name}.ttf'))
    f = skia.Font(_tf_cache[key], size)
    f.setSubpixel(True); f.setEdging(skia.Font.Edging.kAntiAlias); f.setHinting(skia.FontHinting.kNone)
    return f
PF_INDEX = {'regular': 3, 'medium': 7, 'semibold': 11, 'light': 15}
def pingfang(weight, size):
    key = ('pf', weight)
    if key not in _tf_cache:
        _tf_cache[key] = skia.Typeface.MakeFromFile(A('PingFang.ttc'), PF_INDEX[weight])
    f = skia.Font(_tf_cache[key], size)
    f.setSubpixel(True); f.setEdging(skia.Font.Edging.kAntiAlias); f.setHinting(skia.FontHinting.kNone)
    return f

def text_width(s, font, tracking=0.0):
    return font.measureText(s) + tracking * max(0, len(s) - 1)

def draw_text(c, s, x, y, font, color, align='left', tracking=0.0, shadow=None):
    w = text_width(s, font, tracking)
    if align == 'center': x -= w / 2
    elif align == 'right': x -= w
    p = skia.Paint(AntiAlias=True, Color=color)
    if shadow:
        sp = skia.Paint(AntiAlias=True, Color=shadow[0], MaskFilter=skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, shadow[1]))
    if tracking == 0:
        if shadow: c.drawString(s, x, y + shadow[2], font, sp)
        c.drawString(s, x, y, font, p)
    else:
        cx = x
        for ch in s:
            if shadow: c.drawString(ch, cx, y + shadow[2], font, sp)
            c.drawString(ch, cx, y, font, p)
            cx += font.measureText(ch) + tracking
    return w

# ------------------------------------------------- continuous (squircle) corners
# Same 60%-smoothing construction as Resources/AppIcon.svg / scripts/make-status-icon.py
_a, _b = (248.6339 - 128) / 116, (216.1509 - 128) / 116
_c, _d = (140.6432 - 128) / 116, (191.3371 - 128) / 116

def smooth_rrect(x, y, w, h, r, corners=(True, True, True, True), path=None):
    """corners = (top-left, top-right, bottom-right, bottom-left). y grows downward."""
    r = min(r, w / 3.2, h / 3.2)
    p = path or skia.Path()
    # corner anchors and rotation turns (shape extends toward -u and +v in local frame)
    spec = [((x + w, y), 0, corners[1]), ((x + w, y + h), 1, corners[2]),
            ((x, y + h), 2, corners[3]), ((x, y), 3, corners[0])]
    def pt(cx, cy, turns, u, v):
        for _ in range(turns): u, v = -v, u
        return (cx + u * r, cy + v * r)
    first = True
    for (cx, cy), turns, on in spec:
        if not on:
            if first: p.moveTo(cx, cy); first = False
            else: p.lineTo(cx, cy)
            continue
        s0 = pt(cx, cy, turns, -1.6, 0)
        if first: p.moveTo(*s0); first = False
        else: p.lineTo(*s0)
        p.cubicTo(*pt(cx, cy, turns, -_a, 0), *pt(cx, cy, turns, -_b, 0), *pt(cx, cy, turns, -_d, _c))
        e = pt(cx, cy, turns, -_c, _d)
        p.arcTo(r, r, 0, skia.Path.ArcSize.kSmall_ArcSize, skia.PathDirection.kCW, e[0], e[1])
        p.cubicTo(*pt(cx, cy, turns, 0, _b), *pt(cx, cy, turns, 0, _a), *pt(cx, cy, turns, 0, 1.6))
    p.close()
    return p

# ---------------------------------------------------------------- images
def sk_image(path_or_pil):
    im = Image.open(path_or_pil) if isinstance(path_or_pil, str) else path_or_pil
    im = im.convert('RGBA')
    arr = np.ascontiguousarray(np.array(im))
    return skia.Image.fromarray(arr, colorType=skia.kRGBA_8888_ColorType, alphaType=skia.kUnpremul_AlphaType)

SAMPLING = skia.SamplingOptions(skia.CubicResampler.Mitchell())

def draw_image(c, img, x, y, w, h, alpha=1.0):
    p = skia.Paint(AntiAlias=True)
    if alpha < 1: p.setAlphaf(alpha)
    c.drawImageRect(img, skia.Rect.MakeXYWH(x, y, w, h), SAMPLING, p)

# ---------------------------------------------------------------- backdrop texture
def draw_backdrop(c, rng, emblems):
    c.clear(BG)
    # 1) Ambient dot grid, as on zhuhanyu.me: 12 pt pitch, 0.9 pt dots, ink @ 8.5%
    grid = 12.0
    dot = skia.Paint(AntiAlias=True, Color=skia.Color(*INK, int(255 * 0.085)))
    ox = (W % grid) / 2 + grid / 2; oy = (H % grid) / 2 + grid / 2
    y = oy
    while y < H:
        x = ox
        while x < W:
            c.drawCircle(x, y, 0.95, dot)
            x += grid
        y += grid
    # 2) Floating dot-matrix emblems (sampled drawings), very faint
    for e in emblems:
        draw_emblem(c, *e)

def emblem_mask(name, cells_w, cells_h):
    """Rasterise a tiny vector drawing into a boolean grid (one cell = one dot)."""
    sc = 8
    surf = skia.Surface(cells_w * sc, cells_h * sc)
    cc = surf.getCanvas(); cc.clear(skia.ColorTRANSPARENT); cc.scale(sc, sc)
    p = skia.Paint(AntiAlias=True, Color=skia.ColorBLACK)
    if name == 'island':      # capsule + note card
        cc.drawPath(smooth_rrect(6, 1, 26, 7, 3.5), p)
        cc.drawPath(smooth_rrect(7, 10.5, 24, 17, 3), p)
        q = skia.Paint(AntiAlias=True, Color=skia.ColorTRANSPARENT, BlendMode=skia.BlendMode.kClear)
        cc.drawRect(skia.Rect.MakeXYWH(10, 14, 11, 1.6), q)
        cc.drawRect(skia.Rect.MakeXYWH(10, 17.5, 16, 1.6), q)
        cc.drawRect(skia.Rect.MakeXYWH(10, 21, 13, 1.6), q)
    elif name == 'spark':     # four-point sparkle
        path = skia.Path(); cx, cy, R = cells_w / 2, cells_h / 2, cells_w / 2 - .5
        for i in range(8):
            ang = -math.pi / 2 + i * math.pi / 4
            rr = R if i % 2 == 0 else R * 0.22
            (path.moveTo if i == 0 else path.lineTo)(cx + rr * math.cos(ang), cy + rr * math.sin(ang))
        path.close(); cc.drawPath(path, p)
    elif name == 'ring':
        q = skia.Paint(AntiAlias=True, Color=skia.ColorBLACK, Style=skia.Paint.kStroke_Style, StrokeWidth=2.2)
        cc.drawCircle(cells_w / 2, cells_h / 2, cells_w / 2 - 1.6, q)
    elif name == 'cursor':
        cc.drawPath(cursor_path(1.0, (2, 1)), p)
    arr = np.array(Image.open(io.BytesIO(surf.makeImageSnapshot().encodeToData().bytes())).convert('RGBA'))[:, :, 3]
    small = arr.reshape(cells_h, sc, cells_w, sc).mean(axis=(1, 3)) / 255.0
    return small

def draw_emblem(c, name, cx, cy, cell, alpha, rot=0.0, size=(0, 0)):
    cw, ch = size if size != (0, 0) else {'island': (38, 29), 'spark': (15, 15), 'ring': (11, 11), 'cursor': (14, 20)}[name]
    m = emblem_mask(name, cw, ch)
    step = 2 if name == 'island' else 1
    if step > 1:
        hh, ww = (ch // step) * step, (cw // step) * step
        m = m[:hh, :ww].reshape(hh // step, step, ww // step, step).mean(axis=(1, 3))
        ch, cw = m.shape; cell *= step
    c.save(); c.translate(cx, cy); c.rotate(rot); c.translate(-cw * cell / 2, -ch * cell / 2)
    for j in range(ch):
        for i in range(cw):
            v = m[j, i]
            if v > 0.4:
                p = skia.Paint(AntiAlias=True, Color=skia.Color(*INK, int(255 * alpha)))
                c.drawCircle(i * cell + cell / 2, j * cell + cell / 2, min(1.5, cell * 0.24), p)
    c.restore()

# ---------------------------------------------------------------- macOS pieces
def cursor_path(k=1.0, off=(0, 0)):
    pts = [(0, 0), (0, 16.6), (3.9, 12.9), (6.4, 18.9), (9.1, 17.8), (6.6, 11.9), (11.9, 11.9)]
    p = skia.Path()
    for i, (x, y) in enumerate(pts):
        (p.moveTo if i == 0 else p.lineTo)(off[0] + x * k, off[1] + y * k)
    p.close(); return p

def draw_cursor(c, x, y, k=1.0):
    path = cursor_path(k, (x, y))
    sh = skia.Paint(AntiAlias=True, Color=skia.Color(0, 0, 0, 90), MaskFilter=skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, 1.6 * k))
    c.save(); c.translate(0, 1.2 * k); c.drawPath(path, sh); c.restore()
    c.drawPath(path, skia.Paint(AntiAlias=True, Color=skia.ColorWHITE, Style=skia.Paint.kStrokeAndFill_Style,
                                StrokeWidth=2.4 * k, StrokeJoin=skia.Paint.kRound_Join))
    c.drawPath(path, skia.Paint(AntiAlias=True, Color=skia.ColorBLACK))

_status_icon = None
def status_icon_image():
    global _status_icon
    if _status_icon is None:
        import cairosvg
        svg = open(os.path.join(ROOT, 'src-res', 'StatusIcon.svg'), 'rb').read()
        png = cairosvg.svg2png(bytestring=svg, output_width=72, output_height=72)
        im = Image.open(io.BytesIO(png)).convert('RGBA')
        a = np.array(im); a[:, :, :3] = 255           # template image -> white in a dark menu bar
        _status_icon = sk_image(Image.fromarray(a))
    return _status_icon

def draw_menubar(c, lang, fg=skia.ColorWHITE):
    sh = (skia.Color(0, 0, 0, 70), 1.2, 0.4)
    y = 21.5
    f_b = pingfang('semibold', 13.5) if lang == 'zh' else sf(700, 13.5)
    f_r = pingfang('regular', 13.5) if lang == 'zh' else sf(500, 13.5)
    apple = sf(500, 15)
    x = 20
    draw_text(c, '\uf8ff', x, y + 0.6, apple, fg, shadow=sh); x += 34
    items = ['访达', '文件', '编辑', '显示', '前往', '窗口', '帮助'] if lang == 'zh' else ['Finder', 'File', 'Edit', 'View', 'Go', 'Window', 'Help']
    for i, it in enumerate(items):
        w = draw_text(c, it, x, y, f_b if i == 0 else f_r, fg, shadow=sh)
        x += w + (20 if lang == 'zh' else 21)
    # right side
    clock = '11月16日 周一  上午9:41' if lang == 'zh' else 'Mon Nov 16  9:41 AM'
    xr = SCREEN_W - 18
    w = draw_text(c, clock, xr, y, f_r, fg, align='right', shadow=sh); xr -= w + 18
    stroke = lambda wdt: skia.Paint(AntiAlias=True, Color=fg, Style=skia.Paint.kStroke_Style, StrokeWidth=wdt, StrokeCap=skia.Paint.kRound_Cap)
    fill = skia.Paint(AntiAlias=True, Color=fg)
    shp = skia.Paint(AntiAlias=True, Color=skia.Color(0, 0, 0, 60), MaskFilter=skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, 1.0))
    def both(drawfn):
        c.save(); c.translate(0, 0.4); drawfn(shp, shp); c.restore(); drawfn(stroke, fill)
    # Control Center (two stacked toggles)
    cx = xr - 9; cy = 16.5
    def cc_icon(st, fi):
        s1 = st(1.3) if callable(st) else st
        f1 = fi
        for k, dy in enumerate((-3.6, 3.6)):
            r = skia.RRect.MakeRectXY(skia.Rect.MakeXYWH(cx - 8, cy + dy - 2.9, 16, 5.8), 2.9, 2.9)
            c.drawRRect(r, s1 if not isinstance(s1, skia.Paint) or s1 is not shp else shp)
            c.drawCircle(cx + (4.9 if k == 0 else -4.9), cy + dy, 1.8, f1)
    both(cc_icon); xr -= 36
    # Wi-Fi
    cx = xr - 8; cy = 21.2
    def wifi(st, fi):
        s1 = st(1.75) if callable(st) else st
        for rr in (11, 7.2):
            c.drawArc(skia.Rect.MakeXYWH(cx - rr, cy - rr, 2 * rr, 2 * rr), 225, 90, False, s1)
        c.drawCircle(cx, cy - 1.6, 1.9, fi)
    both(wifi); xr -= 38
    # Battery
    bx = xr - 26; by = 11
    def battery(st, fi):
        s1 = st(1.0) if callable(st) else st
        c.drawPath(smooth_rrect(bx, by, 24, 11.5, 3.6), s1)
        c.drawPath(smooth_rrect(bx + 2, by + 2, 15.5, 7.5, 1.8), fi)
        c.drawRRect(skia.RRect.MakeRectXY(skia.Rect.MakeXYWH(bx + 25, by + 3.8, 1.6, 4), .8, .8), fi)
    both(battery); xr -= 40
    # Island Note status item (real template asset from the app bundle)
    ic = status_icon_image()
    draw_image(c, ic, xr - 18, 16.5 - 9, 18, 18)

def draw_notch(c):
    cx = SCREEN_W / 2
    p = smooth_rrect(cx - NOTCH_W / 2, -20, NOTCH_W, NOTCH_H + 20, 9.5, corners=(False, False, True, True))
    c.drawPath(p, skia.Paint(AntiAlias=True, Color=skia.ColorBLACK))

# ---------------------------------------------------------------- screen content
def load_state(lang, state):
    j = json.load(open(CAP(f'{lang}-{state}.json')))
    wins = []
    for w in j['windows']:
        f = CAP(f"{lang}-{state}-w{w['number']}.png")
        if os.path.exists(f):
            wins.append((w, f))
    return j, wins

def cocoa_to_top(frame):
    x, y, w, h = frame
    return x, SCREEN_H - (y + h), w, h

_wall = {}
def wallpaper(kind='light'):
    if kind not in _wall:
        im = Image.open(A('Gold-Gate-wallpaper.png' if kind == 'light' else 'Gold-Gate-wallpaper-dark.png')).convert('RGB')
        _wall[kind] = sk_image(im)
    return _wall[kind]

def render_screen(lang, layers, cursor=None, wall='light', k=3):
    """Return a skia.Image of the full display (SCREEN_W x SCREEN_H pt) at 3x for crisp zooms."""
    surf = skia.Surface(int(SCREEN_W * k), int(SCREEN_H * k))
    c = surf.getCanvas(); c.scale(k, k)
    img = wallpaper(wall)
    iw, ih = img.width(), img.height()
    s = max(SCREEN_W / iw, SCREEN_H / ih)
    dw, dh = iw * s, ih * s
    draw_image(c, img, (SCREEN_W - dw) / 2, (SCREEN_H - dh) / 2, dw, dh)
    # subtle top scrim so the transparent menu bar reads, like macOS does on bright wallpapers
    sc = skia.Paint(Shader=skia.GradientShader.MakeLinear([(0, 0), (0, 60)], [skia.Color(0, 0, 0, 46), skia.Color(0, 0, 0, 0)]))
    c.drawRect(skia.Rect.MakeWH(SCREEN_W, 60), sc)
    draw_menubar(c, lang)
    for layer in layers:
        layer(c)
    draw_notch(c)
    if cursor: draw_cursor(c, *cursor)
    return surf.makeImageSnapshot()

def window_layer(path, frame_top, dx=0, dy=0):
    img = sk_image(path)
    x, y, w, h = frame_top
    def f(c): draw_image(c, img, x + dx, y + dy, w, h)
    return f

def shadow_window_layer(shadow_path, plain_path, at):
    """Place a captured window (with its real macOS shadow) so its body's top-left is at `at`."""
    sh = Image.open(shadow_path).convert('RGBA'); pl = Image.open(plain_path).convert('RGBA')
    a = np.array(sh)[:, :, 3]
    ys, xs = np.where(a >= 250)
    bx, by = xs.min(), ys.min()
    img = sk_image(sh)
    def f(c): draw_image(c, img, at[0] - bx / 2, at[1] - by / 2, sh.width / 2, sh.height / 2)
    return f, (pl.width / 2, pl.height / 2)

def state_layers(lang, state, dx=0, dy=0, skip_status=True):
    j, wins = load_state(lang, state)
    layers = []
    # Panel first, overlay (anchor + bridge) on top, matching orderFrontRegardless in PanelDragCoordinator
    wins.sort(key=lambda t: (t[0]['class'] != 'IslandPanel',))
    for w, f in wins:
        if w['class'] == 'NSStatusBarWindow': continue
        if w['class'] not in ('IslandPanel', 'NSPanel', 'NSWindow') and 'Settings' in w.get('title', ''): continue
        if w.get('title') in ('Settings', '设置'): continue
        if 'shadow' in f: continue
        move = w['class'] == 'IslandPanel'   # only the note panel moves; the island anchor stays in the notch
        layers.append(window_layer(f, cocoa_to_top(w['frame']), dx if move else 0, dy if move else 0))
    return j, layers

# ---------------------------------------------------------------- device
SCREEN_R, BEZEL, LIP = 10.5, 15.0, 2.2

def draw_device(c, screen_img, s, focus, at, shadow=True):
    """Draw the MacBook display so that screen point `focus` lands on canvas point `at`."""
    fx, fy = focus; ax, ay = at
    sx, sy = ax - fx * s, ay - fy * s
    sw, sh = SCREEN_W * s, SCREEN_H * s
    b, l = BEZEL * s, LIP * s
    r_screen = SCREEN_R * s; r_bezel = r_screen + b; r_lip = r_bezel + l
    outer = (sx - b - l, sy - b - l, sw + 2 * (b + l), sh + 2 * (b + l) + 400)
    # soft contact shadow on the paper
    if shadow:
        shp = skia.Paint(AntiAlias=True, Color=skia.Color(30, 25, 15, 46), MaskFilter=skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, 34))
        c.save(); c.translate(0, 18); c.drawPath(smooth_rrect(*outer, r_lip), shp); c.restore()
        shp2 = skia.Paint(AntiAlias=True, Color=skia.Color(30, 25, 15, 40), MaskFilter=skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, 4))
        c.save(); c.translate(0, 2); c.drawPath(smooth_rrect(*outer, r_lip), shp2); c.restore()
    # aluminium lip (space black finish) with a hairline highlight
    lip = skia.Paint(AntiAlias=True, Shader=skia.GradientShader.MakeLinear([(0, outer[1]), (0, outer[1] + 300)],
                     [skia.Color(70, 70, 74), skia.Color(38, 38, 41)]))
    c.drawPath(smooth_rrect(*outer, r_lip), lip)
    hl = skia.Paint(AntiAlias=True, Color=skia.Color(255, 255, 255, 40), Style=skia.Paint.kStroke_Style, StrokeWidth=0.8)
    c.drawPath(smooth_rrect(outer[0] + .4, outer[1] + .4, outer[2] - .8, outer[3] - .8, r_lip - .4), hl)
    # glass bezel
    bez = (sx - b, sy - b, sw + 2 * b, sh + 2 * b + 400)
    c.drawPath(smooth_rrect(*bez, r_bezel), skia.Paint(AntiAlias=True, Color=skia.Color(6, 6, 7)))
    # display (concentric radius)
    clip = smooth_rrect(sx, sy, sw, sh, r_screen, corners=(True, True, False, False))
    c.save(); c.clipPath(clip, skia.ClipOp.kIntersect, True)
    draw_image(c, screen_img, sx, sy, sw, sh)
    c.restore()

# ---------------------------------------------------------------- slide
COPY = {
  'hero': {
    'zh': ('刘海里，藏着一页笔记', '鼠标移到屏幕顶部，笔记就从刘海里展开。'),
    'en': ('A notepad, tucked in the notch.', 'Move to the top of the screen and your note unfolds from the island.')},
  'hover': {
    'zh': ('不用时，它就是刘海', '安静地收在屏幕顶端。悬停即可唤出，移开自动收起。'),
    'en': ('Out of sight until you need it.', 'It rests quietly in the notch. Hover to open, move away to tuck it back.')},
  'markdown': {
    'zh': ('Markdown，边写边排版', '标题、待办、引用实时渲染。写完按 Esc，随手收起。'),
    'en': ('Markdown, rendered as you type.', 'Headings, to-dos and quotes render live. Press Esc to put it away.')},
  'drag': {
    'zh': ('一拖，就成浮动便签', '拖出来放在任意位置，边角自由缩放；拖回刘海，自动吸附归位。'),
    'en': ('Pull it out. Pin it anywhere.', 'Drag the note free, resize from any edge, and drop it back to snap home.')},
  'file': {
    'zh': ('就是一个 Markdown 文件', '存在你选的位置，iCloud Drive、Obsidian 库都可以。无需账号，不联网。'),
    'en': ('Just a Markdown file. Yours.', 'Keep it anywhere, from iCloud Drive to your Obsidian vault. No account, no network.')},
}

def headline(c, lang, title, sub):
    if lang == 'zh':
        tf, sfnt = pingfang('semibold', 50), pingfang('regular', 21)
        tr_t, tr_s = 1.0, 0.4
    else:
        tf, sfnt = sf(640, 52), sf(420, 21.5)
        tr_t, tr_s = 0.0, 0.0
    draw_text(c, title, W / 2, 110, tf, skia.Color(*INK), align='center', tracking=tr_t)
    draw_text(c, sub, W / 2, 154, sfnt, INK2, align='center', tracking=tr_s)

def make_slide(name, lang, out_path, seed):
    rng = random.Random(seed)
    surf = skia.Surface(W * SCALE, H * SCALE)
    c = surf.getCanvas(); c.scale(SCALE, SCALE)
    emb = EMBLEMS[name]
    draw_backdrop(c, rng, emb)
    title, sub = COPY[name][lang]
    headline(c, lang, title, sub)
    DEVICE_TOP = 206
    if name == 'hero':
        _, layers = state_layers(lang, 'expanded')
        scr = render_screen(lang, layers)
        s = 0.86
        draw_device(c, scr, s, (SCREEN_W / 2, 0), (W / 2, DEVICE_TOP + (BEZEL + LIP) * s))
    elif name == 'hover':
        # Two zoomed views of the same display, same scale: at rest vs. on hover.
        rest_lang = lang if os.path.exists(CAP(f'{lang}-rest.json')) and any(
            os.path.exists(CAP(f"{lang}-rest-w{w['number']}.png")) for w in json.load(open(CAP(f'{lang}-rest.json')))['windows']) else 'zh'
        _, rest_layers = state_layers(rest_lang, 'rest')
        _, hover_layers = state_layers(lang, 'hover')
        s = 2.0
        cw, chh, gap = 616, 500, 44
        x0 = (W - (2 * cw + gap)) / 2; y0 = DEVICE_TOP + 26
        caps = {'zh': ('平时，与刘海融为一体', '悬停，轻轻探出'),
                'en': ('At rest, it blends into the notch.', 'On hover, it gently reaches out.')}[lang]
        cursors = [(SCREEN_W / 2 + 70, 58, 1.0), (SCREEN_W / 2 + 40, 22, 1.0)]
        for idx, layers in enumerate((rest_layers, hover_layers)):
            scr = render_screen(lang, layers, cursor=cursors[idx], k=4)
            cx = x0 + idx * (cw + gap)
            card = smooth_rrect(cx, y0, cw, chh, 26)
            shp = skia.Paint(AntiAlias=True, Color=skia.Color(30, 25, 15, 40), MaskFilter=skia.MaskFilter.MakeBlur(skia.kNormal_BlurStyle, 22))
            c.save(); c.translate(0, 12); c.drawPath(card, shp); c.restore()
            c.save(); c.clipPath(card, skia.ClipOp.kIntersect, True)
            c.drawPaint(skia.Paint(Color=skia.Color(6, 6, 7)))
            draw_device(c, scr, s, (SCREEN_W / 2, 0), (cx + cw / 2, y0 + 24), shadow=False)
            c.restore()
            c.drawPath(card, skia.Paint(AntiAlias=True, Color=skia.Color(0, 0, 0, 22), Style=skia.Paint.kStroke_Style, StrokeWidth=1))
            capf = pingfang('medium', 18) if lang == 'zh' else sf(500, 18.5)
            draw_text(c, caps[idx], cx + cw / 2, y0 + chh + 40, capf, INK2, align='center')
    elif name == 'markdown':
        _, layers = state_layers(lang, 'expanded')
        scr = render_screen(lang, layers)
        s = 1.32
        draw_device(c, scr, s, (SCREEN_W / 2, 0), (W / 2, DEVICE_TOP + 12 + (BEZEL + LIP) * s))
    elif name == 'drag':
        _, layers = state_layers(lang, 'docking')
        scr = render_screen(lang, layers)
        s = 0.94
        draw_device(c, scr, s, (SCREEN_W / 2, 0), (W / 2, DEVICE_TOP + (BEZEL + LIP) * s))
    elif name == 'file':
        _, layers = state_layers(lang, 'floating', dx=-70, dy=-95)
        st = json.load(open(CAP(f'{lang}-settings.json')))
        sw = [w for w in st['windows'] if w.get('title') in ('Settings', '设置')][0]
        n = sw['number']
        lay, size = shadow_window_layer(CAP(f'{lang}-settings-w{n}-shadow.png'), CAP(f'{lang}-settings-w{n}.png'), (230, 190))
        layers = [lay] + layers
        scr = render_screen(lang, layers)
        s = 0.80
        draw_device(c, scr, s, (SCREEN_W / 2, 0), (W / 2, DEVICE_TOP + (BEZEL + LIP) * s))
    img = surf.makeImageSnapshot()
    pil = Image.open(io.BytesIO(img.encodeToData().bytes())).convert('RGB')   # no alpha for App Store
    pil.save(out_path, optimize=True)
    return pil

# emblem placements per slide: (name, cx, cy, cell, alpha, rot)
EMBLEMS = {
  'hero':     [('island', 150, 120, 3.6, 0.20, -6), ('spark', 1290, 92, 3.4, 0.22, 0), ('ring', 1350, 170, 3.0, 0.16, 0)],
  'hover':    [('cursor', 1300, 118, 3.4, 0.20, -8), ('spark', 140, 90, 3.0, 0.20, 0), ('ring', 95, 170, 3.0, 0.15, 0)],
  'markdown': [('island', 1290, 112, 3.4, 0.19, 7), ('spark', 130, 150, 3.4, 0.20, 0)],
  'drag':     [('spark', 1310, 140, 3.4, 0.21, 0), ('island', 145, 108, 3.4, 0.18, -9), ('ring', 1240, 70, 2.8, 0.14, 0)],
  'file':     [('ring', 1300, 96, 3.4, 0.17, 0), ('spark', 120, 120, 3.2, 0.21, 0), ('island', 1350, 175, 2.6, 0.14, 5)],
}
ORDER = ['hero', 'hover', 'markdown', 'drag', 'file']

if __name__ == '__main__':
    langs = sys.argv[1:] or ['zh', 'en']
    for lang in langs:
        d = os.path.join(ROOT, lang); os.makedirs(d, exist_ok=True)
        for i, name in enumerate(ORDER, 1):
            p = os.path.join(d, f'{i:02d}-{name}.png')
            make_slide(name, lang, p, seed=i)
            print(p)
