import json, math

W = H = 512
FR, OP = 60, 120          # 2 секунды, бесшовный цикл
BASE = (256, 452)          # точка опоры пламени

# --- Базовый силуэт: (x, y, гладкость). Обход по часовой от кончика ---
OUTER = [
    (262, 52, 0.0),   # 0 главный кончик
    (318, 148, 0.9),  # 1
    (372, 232, 0.9),  # 2
    (398, 326, 0.9),  # 3
    (372, 412, 0.9),  # 4
    (256, 458, 0.9),  # 5 низ
    (140, 412, 0.9),  # 6
    (114, 322, 0.9),  # 7
    (128, 236, 0.7),  # 8
    (150, 150, 0.0),  # 9 левый язычок
    (196, 214, 0.6),  # 10 впадина
    (226, 128, 0.7),  # 11
]

# Варианты (дельты по индексам) — фазы «дыхания» огня
VARIANTS = [
    {},
    {0: (22, 10), 1: (14, 4), 2: (8, 0), 9: (-10, 14), 10: (4, 6), 11: (10, 4), 3: (6, 0)},
    {0: (-16, -8), 1: (-6, -6), 9: (8, -12), 10: (-2, -6), 11: (-10, -4), 7: (-6, 0), 2: (-4, 2)},
    {0: (10, 16), 1: (8, 6), 9: (-4, 20), 10: (6, 10), 11: (4, 8), 3: (-6, 0), 7: (6, 0)},
]


def build(variant, scale, warp=None, src=None):
    pts = []
    for i, (x, y, s) in enumerate(src or OUTER):
        dx, dy = variant.get(i, (0, 0))
        x, y = x + dx, y + dy
        # масштаб к точке опоры
        x = BASE[0] + (x - BASE[0]) * scale
        y = BASE[1] + (y - BASE[1]) * scale
        if warp:
            x, y = warp(x, y)
        pts.append((x, y, s))
    n = len(pts)
    v, ii, oo = [], [], []
    for k in range(n):
        x, y, s = pts[k]
        px, py, _ = pts[k - 1]
        nx, ny, _ = pts[(k + 1) % n]
        tx, ty = (nx - px) * s / 6, (ny - py) * s / 6
        v.append([round(x, 2), round(y, 2)])
        oo.append([round(tx, 2), round(ty, 2)])
        ii.append([round(-tx, 2), round(-ty, 2)])
    return {"i": ii, "o": oo, "v": v, "c": True}


EASE = {"i": {"x": [0.45], "y": [1]}, "o": {"x": [0.55], "y": [0]}}
EASE2 = {"i": {"x": [0.45, 0.45], "y": [1, 1]}, "o": {"x": [0.55, 0.55], "y": [0, 0]}}


LIN = {"i": {"x": [1], "y": [1]}, "o": {"x": [0], "y": [0]}}
STEP = 4  # ключ каждые 4 кадра — плавное извивание


def blend_variant(t, order):
    """Плавное (косинусное) смешивание фаз мерцания по циклу 120 кадров."""
    seg = (t % OP) / 30
    a = int(seg) % 4
    b = (a + 1) % 4
    f = (1 - math.cos(math.pi * (seg - int(seg)))) / 2
    va, vb = VARIANTS[order[a]], VARIANTS[order[b]]
    out = {}
    for k in set(va) | set(vb):
        ax, ay = va.get(k, (0, 0))
        bx, by = vb.get(k, (0, 0))
        out[k] = (ax + (bx - ax) * f, ay + (by - ay) * f)
    return out


def make_warp(t, lag):
    """Бегущая вверх волна: основание стоит, верх извивается змейкой."""
    ph = 2 * math.pi * t / OP
    def warp(x, y):
        h = max(0.0, min(1.0, (BASE[1] - y) / 400))
        w = h ** 1.25
        dx = (38 * math.sin(2 * ph - 2.8 * h - lag)
              + 14 * math.sin(3 * ph - 4.5 * h - lag * 1.5))
        dy = -6 * w * math.sin(2 * ph - 2.8 * h - lag + 1.2)
        return x + dx * w, y + dy
    return warp


def shape_anim(scale, order, lag, src=None, dx0=0):
    kfs = []
    for t in range(0, OP + 1, STEP):
        var = blend_variant(t, order) if src is None else {}
        w = make_warp(t, lag)
        sh = build(var, scale, (lambda x, y, w=w: w(x + dx0, y)), src)
        kf = {"t": t, "s": [sh]}
        if t != OP:
            kf.update(LIN)
        kfs.append(kf)
    return {"a": 1, "k": kfs}


def hexrgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def grad(stops, start, end, kind=1, opac=None):
    k = []
    for p, c in stops:
        k += [p] + hexrgb(c)
    g = {"p": len(stops), "k": {"a": 0, "k": k}}
    if opac:
        for p, o in opac:
            k += [p, o]
    return {"ty": "gf", "o": {"a": 0, "k": 100}, "r": 1, "bm": 0,
            "s": {"a": 0, "k": list(start)}, "e": {"a": 0, "k": list(end)},
            "t": kind, "g": g, "nm": "Gradient"}


def tr():
    return {"ty": "tr", "p": {"a": 0, "k": [0, 0]}, "a": {"a": 0, "k": [0, 0]},
            "s": {"a": 0, "k": [100, 100]}, "r": {"a": 0, "k": 0},
            "o": {"a": 0, "k": 100}, "sk": {"a": 0, "k": 0}, "sa": {"a": 0, "k": 0}}


def layer(ind, name, shapes, ks=None, ip=0, op=OP):
    base_ks = {"o": {"a": 0, "k": 100}, "r": {"a": 0, "k": 0},
               "p": {"a": 0, "k": [0, 0, 0]}, "a": {"a": 0, "k": [0, 0, 0]},
               "s": {"a": 0, "k": [100, 100, 100]}}
    if ks:
        base_ks.update(ks)
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": name, "sr": 1, "ks": base_ks,
            "ao": 0, "shapes": shapes, "ip": ip, "op": op, "st": 0, "bm": 0}


# Общее «дыхание» всего пламени (растяжение вверх от основания)
breath = {
    "a": {"a": 0, "k": [BASE[0], BASE[1], 0]},
    "p": {"a": 0, "k": [BASE[0], BASE[1], 0]},
    "s": {"a": 1, "k": [
        {"t": 0, "s": [100, 100, 100], **EASE2},
        {"t": 12, "s": [94, 109, 100], **EASE2},
        {"t": 26, "s": [105, 95, 100], **EASE2},
        {"t": 38, "s": [98, 102, 100], **EASE2},
        {"t": 60, "s": [100, 100, 100], **EASE2},
        {"t": 72, "s": [95, 107, 100], **EASE2},
        {"t": 86, "s": [104, 96, 100], **EASE2},
        {"t": 98, "s": [99, 101, 100], **EASE2},
        {"t": 120, "s": [100, 100, 100]},
    ]},
}

flames = [  # имя, масштаб, порядок фаз, градиент, цвет тени
    ("Outer", 1.00, [0, 1, 2, 3], [(0, "#FF2D2D"), (0.5, "#FF4A1C"), (1, "#FF8A00")], "#C2121F"),
    ("Middle", 0.74, [2, 3, 0, 1], [(0, "#FF7A00"), (1, "#FFB800")], "#E04E00"),
    ("Inner", 0.50, [1, 2, 3, 0], [(0, "#FFC400"), (1, "#FFE94D")], "#F59A00"),
    ("Core", 0.27, [3, 0, 1, 2], [(0, "#FFF6B8"), (1, "#FFFFFF")], "#FFD24D"),
]

# Блик: тонкий глянцевый штрих слева (в системе координат силуэта)
HL = [(160, 236, 0.0), (146, 290, 0.8), (146, 350, 0.8), (162, 398, 0.0),
      (164, 352, 0.8), (166, 296, 0.8)]
HL_DOT = [(186, 196, 0.0), (176, 214, 0.9), (184, 226, 0.0), (192, 212, 0.9)]

layers = []
ind = 1

# Искры (сверху всех слоёв)
sparks = [  # (старт, x0, x1, размер, цвет)
    (0, 300, 334, 14, "#FFC23A"),
    (38, 210, 172, 11, "#FF8A1F"),
    (70, 268, 290, 9, "#FFE066"),
]
for st, x0, x1, sz, col in sparks:
    d = 48
    pos = {"a": 1, "k": [
        {"t": st, "s": [x0, 150, 0], "i": {"x": [0.4], "y": [1]}, "o": {"x": [0.3], "y": [0]}},
        {"t": st + d, "s": [x1, 40, 0]},
    ]}
    opa = {"a": 1, "k": [
        {"t": st, "s": [0], **EASE}, {"t": st + 10, "s": [100], **EASE},
        {"t": st + d, "s": [0]},
    ]}
    scl = {"a": 1, "k": [
        {"t": st, "s": [100, 100, 100], **EASE2}, {"t": st + d, "s": [30, 30, 100]},
    ]}
    el = {"ty": "gr", "nm": "Spark", "it": [
        {"ty": "el", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [sz, sz]}, "d": 1},
        {"ty": "fl", "c": {"a": 0, "k": hexrgb(col) + [1]}, "o": {"a": 0, "k": 100}, "r": 1},
        tr()]}
    layers.append(layer(ind, f"Spark {ind}", [el], {"p": pos, "o": opa, "s": scl}))
    ind += 1

# Языки пламени: ядро сверху, внешний — снизу
def solid(col, op=100):
    return {"ty": "fl", "c": {"a": 0, "k": hexrgb(col) + [1]}, "o": {"a": 0, "k": op}, "r": 1}


for li, (name, sc, order, stops, shade) in enumerate(reversed(flames)):
    lag = 0.35 * (3 - li)
    groups = []
    if name == "Outer":
        for nm, src, op in (("Highlight", HL, 60), ("Highlight dot", HL_DOT, 70)):
            groups.append({"ty": "gr", "nm": nm, "it": [
                {"ty": "sh", "ks": shape_anim(1.0, order, lag, src=src), "nm": "Path"},
                solid("#FFFFFF", op), tr()]})
    if name == "Middle":
        groups.append({"ty": "gr", "nm": "Highlight", "it": [
            {"ty": "sh", "ks": shape_anim(0.74, order, lag, src=HL), "nm": "Path"},
            solid("#FFF3C4", 55), tr()]})
    # основной объём, чуть уже и сдвинут влево — справа остаётся тень
    groups.append({"ty": "gr", "nm": name, "it": [
        {"ty": "sh", "ks": shape_anim(sc * 0.94, order, lag, dx0=-7 * sc), "nm": "Path"},
        grad(stops, (256, BASE[1] - 400 * sc), (256, BASE[1])), tr()]})
    groups.append({"ty": "gr", "nm": name + " shade", "it": [
        {"ty": "sh", "ks": shape_anim(sc, order, lag), "nm": "Path"},
        solid(shade), tr()]})
    layers.append(layer(ind, name, groups, breath))
    ind += 1

# Свечение позади
glow_scale = {"a": 1, "k": [
    {"t": 0, "s": [100, 100, 100], **EASE2},
    {"t": 60, "s": [110, 108, 100], **EASE2},
    {"t": 120, "s": [100, 100, 100]},
]}
glow = {"ty": "gr", "nm": "Glow", "it": [
    {"ty": "el", "p": {"a": 0, "k": [0, 0]}, "s": {"a": 0, "k": [440, 440]}, "d": 1},
    grad([(0, "#FF7A1A"), (1, "#FF3D1A")], (0, 0), (220, 0), kind=2,
         opac=[(0, 0.45), (0.6, 0.15), (1, 0)]),
    tr()]}
layers.append(layer(ind, "Glow", [glow], {
    "p": {"a": 0, "k": [256, 300, 0]}, "s": glow_scale}))

anim = {"v": "5.12.2", "fr": FR, "ip": 0, "op": OP, "w": W, "h": H,
        "nm": "Orbita 🔥", "ddd": 0, "assets": [], "layers": layers}

import os, sys
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "Orbita", "DesignSystem", "Emoji")
with open(os.path.join(OUT, "emoji_1f525.json"), "w") as f:
    json.dump(anim, f, separators=(",", ":"))

html = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Fire Lottie</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#1b1210}
#a{width:min(90vw,420px);aspect-ratio:1}</style></head><body><div id="a"></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js"></script>
<script>lottie.loadAnimation({container:document.getElementById('a'),renderer:'svg',loop:true,autoplay:true,animationData:%s});</script>
</body></html>""" % json.dumps(anim, separators=(",", ":"))
with open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "preview_1f525.html"), "w") as f:
    f.write(html)
print("ok", len(json.dumps(anim)))
