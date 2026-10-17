"""Наш 👍 для Orbita: объёмная жёлтая рука с поднятым большим пальцем.

Анимация (2 с, цикл): замах назад, упругий «тык» вперёд с растяжением, палец
пружинит с запаздыванием, вокруг вспыхивают звёздочки; во второй половине
цикла — короткий кивок. Запуск: python3 tools/emoji/thumbs_up.py
"""
import json, os

W = H = 512
FR, OP = 60, 120
HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "..", "..", "Orbita", "DesignSystem", "Emoji", "emoji_1f44d.json")

E1 = {"i": {"x": [0.4], "y": [1]}, "o": {"x": [0.6], "y": [0]}}
E2 = {"i": {"x": [0.4, 0.4], "y": [1, 1]}, "o": {"x": [0.6, 0.6], "y": [0, 0]}}


def hexrgb(h):
    h = h.lstrip("#")
    return [int(h[i:i + 2], 16) / 255 for i in (0, 2, 4)]


def st(v):
    return {"a": 0, "k": v}


def anim1(pairs):
    ks = [{"t": t, "s": [v], **E1} for t, v in pairs]
    ks[-1] = {"t": pairs[-1][0], "s": [pairs[-1][1]]}
    return {"a": 1, "k": ks}


def anim2(pairs):
    ks = [{"t": t, "s": list(v) + [100], **E2} for t, v in pairs]
    ks[-1] = {"t": pairs[-1][0], "s": list(pairs[-1][1]) + [100]}
    return {"a": 1, "k": ks}


def tr(p=(0, 0), s=(100, 100), r=0, o=100):
    return {"ty": "tr", "p": st(list(p)), "a": st([0, 0]), "s": st(list(s)),
            "r": st(r), "o": st(o), "sk": st(0), "sa": st(0)}


def solid(col, o=100):
    return {"ty": "fl", "c": st(hexrgb(col) + [1]), "o": st(o), "r": 1}


def grad(c0, c1, start, end):
    k = [0] + hexrgb(c0) + [1] + hexrgb(c1)
    return {"ty": "gf", "o": st(100), "r": 1, "s": st(list(start)), "e": st(list(end)),
            "t": 1, "g": {"p": 2, "k": st(k)}}


def rc(cx, cy, w, h, r):
    return {"ty": "rc", "p": st([cx, cy]), "s": st([w, h]), "r": st(r), "d": 1}


def bpath(pts, dx=0, dy=0, k=1.0, c=None):
    """Гладкий замкнутый контур по точкам (x, y, гладкость); k — масштаб к центру c."""
    if c is None:
        c = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts))
    P = [(c[0] + (x - c[0]) * k + dx, c[1] + (y - c[1]) * k + dy, sm) for x, y, sm in pts]
    v, ii, oo = [], [], []
    n = len(P)
    for j in range(n):
        x, y, sm = P[j]
        px, py, _ = P[j - 1]
        nx, ny, _ = P[(j + 1) % n]
        tx, ty = (nx - px) * sm / 6, (ny - py) * sm / 6
        v.append([round(x, 2), round(y, 2)])
        oo.append([round(tx, 2), round(ty, 2)])
        ii.append([round(-tx, 2), round(-ty, 2)])
    return {"ty": "sh", "ks": st({"i": ii, "o": oo, "v": v, "c": True})}


def puffy_path(nm, pts, top, bottom, shade, dx=-5, dy=-6, k=0.97, extra=()):
    ys = [p[1] for p in pts]
    gs = list(extra)
    gs.append(group(nm, [bpath(pts, dx, dy, k), grad(top, bottom, (0, min(ys)), (0, max(ys)))]))
    gs.append(group(nm + " shade", [bpath(pts), solid(shade)]))
    return gs


def group(nm, items):
    return {"ty": "gr", "nm": nm, "it": items + [tr()]}


def puffy(nm, cx, cy, w, h, r, top, bottom, shade, dx=-5, dy=-6, hl=None):
    """Деталь с объёмом: тёмная подложка, поверх — светлая форма, сдвинутая вверх-влево, и блик."""
    gs = []
    if hl:
        hx, hy, hw, hh, ho = hl
        gs.append(group(nm + " highlight", [rc(hx, hy, hw, hh, min(hw, hh) / 2), solid("#FFFFFF", ho)]))
    gs.append(group(nm, [rc(cx + dx, cy + dy, w - 8, h - 8, max(r - 4, 0)),
                         grad(top, bottom, (cx, cy - h / 2), (cx, cy + h / 2))]))
    gs.append(group(nm + " shade", [rc(cx, cy, w, h, r), solid(shade)]))
    return gs


def layer(ind, nm, shapes, ks=None, parent=None, ty=4):
    base = {"o": st(100), "r": st(0), "p": st([0, 0, 0]), "a": st([0, 0, 0]), "s": st([100, 100, 100])}
    base.update(ks or {})
    l = {"ddd": 0, "ind": ind, "ty": ty, "nm": nm, "sr": 1, "ks": base, "ao": 0,
         "ip": 0, "op": OP, "st": 0, "bm": 0}
    if ty == 4:
        l["shapes"] = shapes
    if parent:
        l["parent"] = parent
    return l


SKIN = ("#FFD84A", "#FFB21E", "#E38D14")

WRIST = (178, 470)
hand_ks = {
    "a": st([*WRIST, 0]), "p": st([*WRIST, 0]),
    "r": anim1([(0, 0), (10, -14), (22, 10), (34, -5), (46, 2), (56, 0),
                (80, 0), (88, -6), (98, 4), (108, 0), (120, 0)]),
    "s": anim2([(0, (100, 100)), (10, (104, 94)), (22, (94, 110)), (34, (103, 97)),
                (46, (99, 101)), (56, (100, 100)), (80, (100, 100)), (88, (103, 97)),
                (98, (98, 103)), (108, (100, 100)), (120, (100, 100))]),
}

THUMB_BASE = (214, 240)
thumb_ks = {
    "a": st([*THUMB_BASE, 0]), "p": st([*THUMB_BASE, 0]),
    "r": anim1([(0, -6), (14, -14), (26, 6), (38, -11), (50, -4), (60, -6),
                (90, -12), (100, 0), (110, -7), (120, -6)]),
}

layers = []

# Звёздочки (сверху, не привязаны к руке)
stars = [  # x, y, размер, цвет, старт
    (300, 64, 30, "#FFC93C", 20),
    (128, 92, 22, "#7FB2FF", 26),
    (330, 150, 18, "#FF9F1C", 32),
]
for i, (x, y, sz, col, t0) in enumerate(stars):
    star = {"ty": "sr", "sy": 1, "pt": st(4), "p": st([0, 0]), "r": st(0),
            "or": st(sz), "ir": st(sz * 0.32), "is": st(0), "os": st(0)}
    ks = {
        "p": st([x, y, 0]),
        "s": anim2([(0, (0, 0)), (t0, (0, 0)), (t0 + 10, (120, 120)), (t0 + 18, (90, 90)),
                    (t0 + 30, (0, 0)), (120, (0, 0))]),
        "r": anim1([(0, 0), (t0, 0), (t0 + 30, 90), (120, 90)]),
    }
    layers.append(layer(len(layers) + 1, f"Star {i + 1}", [group("Star", [star, solid(col)])], ks))

# рука чуть меньше и по центру холста
SC = 0.92
hand_ks["p"] = st([WRIST[0] + 22, WRIST[1] - 12, 0])
for kf in hand_ks["s"]["k"]:
    kf["s"] = [kf["s"][0] * SC, kf["s"][1] * SC, 100]
hand = len(layers) + 1
layers.append(layer(hand, "Hand", None, hand_ks, ty=3))

# Четыре пальца, сложенные в кулак (сверху вниз)
fingers = []
for k, (y, right, h) in enumerate(((248, 382, 64), (300, 388, 62), (352, 380, 60), (400, 358, 54))):
    w = right - 262
    hl = (right - 54, y - 15, 32, 10, 55) if k == 0 else None
    fingers += puffy(f"Finger {k + 1}", right - w / 2, y, w, h, h / 2, *SKIN, hl=hl)
layers.append(layer(len(layers) + 1, "Fingers", fingers, parent=hand))

# Ладонь, плавно переходящая в запястье
PALM = [(172, 222, 0.8), (240, 208, 0.8), (300, 222, 0.8), (330, 300, 0.8), (326, 400, 0.8),
        (290, 444, 0.8), (240, 470, 0.8), (190, 478, 0.8), (148, 464, 0.8), (132, 410, 0.8),
        (140, 320, 0.8)]
layers.append(layer(len(layers) + 1, "Palm",
                    puffy_path("Palm", PALM, *SKIN, extra=[
                        group("Palm highlight", [rc(166, 330, 14, 100, 7), solid("#FFFFFF", 45)])]),
                    parent=hand))

# Большой палец: толще у основания, чуть изогнут, с ногтем (за ладонью, своя пружинка)
THUMB = [(170, 262, 0.6), (164, 180, 0.8), (172, 108, 0.8), (204, 62, 0.9), (246, 68, 0.9),
         (266, 120, 0.8), (262, 190, 0.8), (264, 262, 0.6)]
layers.append(layer(len(layers) + 1, "Thumb",
                    puffy_path("Thumb", THUMB, *SKIN, extra=[
                        group("Thumb highlight", [rc(186, 128, 14, 76, 7), solid("#FFFFFF", 60)]),
                        group("Nail", [{"ty": "el", "p": st([238, 96]), "s": st([34, 46]), "d": 1},
                                       solid("#FFF1B8", 75)])]),
                    thumb_ks, parent=hand))

anim = {"v": "5.12.2", "fr": FR, "ip": 0, "op": OP, "w": W, "h": H,
        "nm": "Orbita 👍", "ddd": 0, "assets": [], "layers": layers}

with open(OUT, "w") as f:
    json.dump(anim, f, separators=(",", ":"))

html = """<!doctype html><html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>Orbita 👍</title>
<style>body{margin:0;min-height:100vh;display:grid;place-items:center;background:#f4f4f7}
#a{width:min(90vw,420px);aspect-ratio:1}</style></head><body><div id="a"></div>
<script src="https://cdnjs.cloudflare.com/ajax/libs/lottie-web/5.12.2/lottie.min.js"></script>
<script>lottie.loadAnimation({container:document.getElementById('a'),renderer:'svg',loop:true,autoplay:true,animationData:%s});</script>
</body></html>""" % json.dumps(anim, separators=(",", ":"))
with open(os.path.join(HERE, "preview_1f44d.html"), "w") as f:
    f.write(html)
print("ok", os.path.getsize(OUT), "bytes")
