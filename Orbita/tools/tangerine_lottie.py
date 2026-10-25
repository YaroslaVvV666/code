"""Новогодний мандарин 🍊 в формате Lottie (как анимированные эмодзи Telegram): 512×512, 60 к/с, 3 с.
Мандарин в шапке Деда Мороза подпрыгивает, шапка и помпон качаются с запаздыванием, листик покачивается,
падают снежинки, мерцают искорки. Последний кадр — спокойная поза (картинка «в покое»)."""
import json, math, random, sys

W = H = 512
FR, OP = 60, 180
random.seed(7)


def st(v):
    return {"a": 0, "k": v}


def kf(frames, ease=(0.42, 0.58)):
    """[(кадр, значение), ...] → анимированное свойство с плавным входом и выходом"""
    keys = []
    for i, (t, v) in enumerate(frames):
        v = v if isinstance(v, list) else [v]
        k = {"t": t, "s": v}
        if i < len(frames) - 1:
            n = len(v)
            k["o"] = {"x": [ease[0]] * n, "y": [0] * n}
            k["i"] = {"x": [ease[1]] * n, "y": [1] * n}
        keys.append(k)
    return {"a": 1, "k": keys}


def tr(p=(0, 0), a=(0, 0), s=(100, 100), r=0, o=100):
    def prop(v):
        return v if isinstance(v, dict) else st(list(v) if isinstance(v, (tuple, list)) else v)
    return {"ty": "tr", "p": prop(p), "a": prop(a), "s": prop(s), "r": prop(r), "o": prop(o),
            "sk": st(0), "sa": st(0)}


def fill(rgb, o=100):
    return {"ty": "fl", "c": st([*rgb, 1]), "o": st(o), "r": 1}


def stroke(rgb, w, o=100):
    return {"ty": "st", "c": st([*rgb, 1]), "o": st(o), "w": st(w), "lc": 2, "lj": 2}


def radial(start, end, stops):
    """stops: [(смещение, (r, g, b)), ...]"""
    k = []
    for off, (r, g, b) in stops:
        k += [off, r, g, b]
    return {"ty": "gf", "t": 2, "s": st(list(start)), "e": st(list(end)), "h": st(0), "a": st(0),
            "g": {"p": len(stops), "k": st(k)}, "o": st(100), "r": 1}


def linear(start, end, stops):
    g = radial(start, end, stops)
    g["t"] = 1
    return g


def ellipse(c, size):
    return {"ty": "el", "p": st(list(c)), "s": st(list(size)), "d": 1}


def rect(c, size, r):
    return {"ty": "rc", "p": st(list(c)), "s": st(list(size)), "r": st(r), "d": 1}


def path(points, closed=True):
    """points: [(x, y, (in_dx, in_dy), (out_dx, out_dy)), ...] — касательные относительно точки"""
    return {"ty": "sh", "ks": st({"c": closed,
                                  "v": [[x, y] for x, y, _, _ in points],
                                  "i": [list(i) for _, _, i, _ in points],
                                  "o": [list(o) for _, _, _, o in points]}), "d": 1}


def group(name, items, transform=None):
    return {"ty": "gr", "nm": name, "it": items + [transform or tr()]}


def layer(ind, name, shapes, ks=None, ip=0, op=OP):
    return {"ddd": 0, "ind": ind, "ty": 4, "nm": name, "sr": 1, "ks": ks or {
        "o": st(100), "r": st(0), "p": st([0, 0, 0]), "a": st([0, 0, 0]), "s": st([100, 100, 100])},
        "ao": 0, "shapes": shapes, "ip": ip, "op": op, "st": 0, "bm": 0}


def layer_ks(p, a, s=None, r=None, o=None):
    def wrap(v, default):
        return v if isinstance(v, dict) else st(default if v is None else v)
    return {"o": wrap(o, 100), "r": wrap(r, 0), "p": wrap(p, p), "a": wrap(a, a), "s": wrap(s, [100, 100, 100])}


# ── прыжок: присел → подпрыгнул → приземлился с приплющиванием → успокоился ──
BOUNCE_T = [0, 10, 28, 40, 54, 62, 76, 90, 120, 150, 180]
DY = [0, 6, -44, -48, 0, 8, -5, 0, 0, 0, 0]
SX = [100, 109, 93, 99, 96, 112, 97, 101, 100, 101.5, 100]
SY = [100, 91, 108, 101, 105, 88, 103, 99, 100, 98.5, 100]
base_y = 432
body_p = kf([(t, [256, base_y + dy, 0]) for t, dy in zip(BOUNCE_T, DY)])
body_s = kf([(t, [sx * 0.93, sy * 0.93, 100]) for t, sx, sy in zip(BOUNCE_T, SX, SY)])     # 0.93 — запас до краёв кадра в прыжке

ORANGE_LIGHT = (1.0, 0.78, 0.28)
ORANGE = (1.0, 0.56, 0.06)
ORANGE_DEEP = (0.93, 0.36, 0.02)

# мандарин: тело с объёмом, поры на кожуре, блик
body = group("тело", [
    ellipse((256, 292), (300, 276)),
    radial((205, 230), (256 + 175, 292 + 130), [(0, ORANGE_LIGHT), (0.5, ORANGE), (1, ORANGE_DEEP)]),
])
pores = []
for x, y, d in [(190, 300, 9), (225, 345, 8), (300, 330, 9), (330, 280, 8), (270, 380, 7), (350, 360, 8),
                (180, 350, 7), (240, 300, 6), (310, 395, 6), (215, 390, 6), (365, 315, 6), (285, 285, 6)]:
    pores.append(ellipse((x, y), (d, d * 0.85)))
pores_g = group("поры", pores + [fill(ORANGE_DEEP, 45)])
shine = group("блик", [ellipse((0, 0), (78, 44)), fill((1, 1, 1), 55)],
              tr(p=(196, 238), r=-32))
shine2 = group("блик2", [ellipse((0, 0), (16, 12)), fill((1, 1, 1), 70)], tr(p=(240, 214)))
rim = group("тень снизу", [ellipse((262, 318), (300, 230)), fill(ORANGE_DEEP, 0)])

# листик: качается от основания
leaf_r = kf([(0, 0), (12, -10), (30, 14), (50, -12), (66, 8), (82, -5), (100, 2), (120, 0), (180, 0)])
leaf = group("листик", [
    path([(196, 176, (0, 0), (-18, -24)),
          (112, 118, (30, 2), (-2, 26)),
          (196, 176, (-40, 14), (0, 0))]),
    linear((196, 176), (112, 118), [(0, (0.22, 0.62, 0.20)), (1, (0.45, 0.82, 0.28))]),
    path([(190, 172, (0, 0), (-20, -14)), (130, 128, (0, 0), (0, 0))], closed=False),
    stroke((0.18, 0.48, 0.16), 4, 70),
], tr(p=(196, 176), a=(196, 176), r=leaf_r))

# шапка Деда Мороза: качается с запаздыванием, помпон болтается ещё позже
RED_LIGHT, RED, RED_DEEP = (0.98, 0.28, 0.25), (0.86, 0.10, 0.12), (0.62, 0.04, 0.08)
WHITE, SNOW_SHADE = (1, 1, 1), (0.86, 0.90, 0.96)
hat_r = kf([(0, 0), (10, -7), (30, 9), (46, 5), (58, -8), (74, 5), (90, -3), (106, 1), (124, 0), (180, 0)])
pom_r = kf([(0, 0), (18, 16), (40, -22), (60, 20), (78, -12), (96, 7), (114, -3), (132, 0), (180, 0)])
cone = group("колпак", [
    path([(168, 196, (0, 0), (10, -70)),
          (312, 60, (-60, -6), (40, 4)),
          (402, 112, (-14, -26), (0, 0)),
          (350, 170, (8, -30), (0, 0))]),
    linear((200, 190), (360, 80), [(0, RED_DEEP), (0.45, RED), (1, RED_LIGHT)]),
])
fold = group("складка", [
    path([(300, 72, (0, 0), (30, 10)), (370, 128, (-6, -24), (0, 0))], closed=False),
    stroke(RED_DEEP, 6, 60),
])
brim = group("опушка", [
    rect((0, 0), (226, 50), 25),
    linear((0, -25), (0, 25), [(0, WHITE), (1, SNOW_SHADE)]),
], tr(p=(258, 190), r=-11))
brim_puffs = group("пушистость", [
    ellipse((175, 205), (34, 30)), ellipse((215, 198), (30, 26)), ellipse((300, 182), (30, 26)),
    ellipse((340, 172), (34, 30)), fill(WHITE, 100),
])
pompom = group("помпон", [
    ellipse((416, 116), (60, 58)),
    radial((404, 104), (440, 140), [(0, WHITE), (1, SNOW_SHADE)]),
], tr(p=(398, 108), a=(398, 108), r=pom_r))
hat = group("шапка", [pompom, cone, fold, brim, brim_puffs], tr(p=(258, 190), a=(258, 190), r=hat_r))

tangerine = layer(10, "мандарин", [hat, leaf, shine2, shine, pores_g, body],
                  layer_ks(body_p, [256, base_y, 0], s=body_s))

# тень на земле: меньше и бледнее, когда мандарин в воздухе
shadow_s = kf([(t, [100 - max(0, -dy) * 0.55, 100 - max(0, -dy) * 0.55, 100]) for t, dy in zip(BOUNCE_T, DY)])
shadow_o = kf([(t, 22 - max(0, -dy) * 0.12) for t, dy in zip(BOUNCE_T, DY)])
shadow = layer(11, "тень", [group("тень", [ellipse((0, 0), (230, 34)), fill((0.1, 0.05, 0.1), 100)])],
               layer_ks([256, 450, 0], [0, 0, 0], s=shadow_s, o=shadow_o))


# ── снежинки: шесть лучей, падают, вращаются, тают до конца анимации ──
def flake_shape(size):
    arms = []
    for k in range(3):
        arms.append(group("луч", [rect((0, 0), (size * 0.16, size), size * 0.08), fill(WHITE, 100)], tr(r=k * 60)))
    tips = []
    for k in range(6):
        a = math.radians(k * 60)
        tips.append(ellipse((math.sin(a) * size * 0.32, -math.cos(a) * size * 0.32), (size * 0.2, size * 0.2)))
    return arms + [group("кончики", tips + [fill(WHITE, 100)])]


flakes = []
for i in range(9):
    x0 = 40 + i * 54 + random.uniform(-14, 14)
    start = int(random.uniform(0, 70))
    dur = int(random.uniform(90, 108))
    end = min(start + dur, OP - 2)
    y0, y1 = random.uniform(-30, 120), random.uniform(380, 520)
    drift = random.uniform(-40, 40)
    size = random.uniform(22, 40)
    front = i % 3 == 0
    p = kf([(start, [x0, y0, 0]), ((start + end) // 2, [x0 + drift, (y0 + y1) / 2, 0]), (end, [x0 - drift * 0.5, y1, 0])],
           ease=(0.3, 0.7))
    r = kf([(start, random.uniform(0, 60)), (end, random.uniform(140, 260))], ease=(0.2, 0.8))
    o = kf([(start, 0), (start + 14, 90 if front else 75), (end - 18, 90 if front else 75), (end, 0)])
    flakes.append((front, layer(0, "снежинка", flake_shape(size), layer_ks(p, [0, 0, 0], r=r, o=o), ip=start, op=end + 1)))


# ── искорки: четырёхконечные звёздочки вспыхивают по очереди ──
def sparkle(c, size, t0):
    s = kf([(t0, [0, 0, 100]), (t0 + 10, [100, 100, 100]), (t0 + 22, [0, 0, 100])], ease=(0.3, 0.7))
    r = kf([(t0, 0), (t0 + 22, 45)])
    pts = []
    for k in range(4):
        a = math.radians(k * 90)
        b = math.radians(k * 90 + 45)
        pts.append((math.sin(a) * size, -math.cos(a) * size, (0, 0), (0, 0)))
        pts.append((math.sin(b) * size * 0.22, -math.cos(b) * size * 0.22, (0, 0), (0, 0)))
    shape = [group("звёздочка", [path(pts), fill((1, 0.95, 0.65), 100)])]
    return layer(0, "искорка", shape, layer_ks([*c, 0], [0, 0, 0], s=s, r=r), ip=t0, op=t0 + 23)


sparkles = [sparkle((96, 250), 26, 30), sparkle((430, 300), 30, 52), sparkle((140, 410), 20, 76),
            sparkle((404, 200), 22, 98), sparkle((90, 140), 18, 120), sparkle((446, 410), 22, 138)]

layers = [s for s in sparkles] + [l for f, l in flakes if f] + [tangerine, shadow] + [l for f, l in flakes if not f]
for i, l in enumerate(layers, 1):
    l["ind"] = i

anim = {"tgs": 1, "v": "5.5.2", "fr": FR, "ip": 0, "op": OP, "w": W, "h": H, "nm": "tangerine", "ddd": 0,
        "assets": [], "layers": layers}
out = sys.argv[1] if len(sys.argv) > 1 else "tangerine.json"
with open(out, "w") as f:
    json.dump(anim, f, separators=(",", ":"))
print(out, len(json.dumps(anim, separators=(",", ":"))), "bytes,", len(layers), "layers")
