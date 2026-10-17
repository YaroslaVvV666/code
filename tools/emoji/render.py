"""Мини-рендерер Lottie для превью наших эмодзи (без браузера).

Поддерживает то, чем пользуются генераторы в tools/emoji: слои-фигуры и null-слои,
родителей, трансформации, группы, sh / rc / el / sr, заливки fl / gf (линейный и радиальный
градиент, прозрачность в градиенте), кривые сглаживания ключей.

    python3 render.py ../../Orbita/DesignSystem/Emoji/emoji_1f525.json out.gif
    python3 render.py anim.json strip.png --frames 0,20,40
"""
import json, math, sys
import numpy as np
from PIL import Image, ImageDraw

SS = 2  # суперсэмплинг


# ---------- ключи ----------
def _bez(t, x1, y1, x2, y2):
    lo, hi = 0.0, 1.0
    for _ in range(30):
        m = (lo + hi) / 2
        x = 3 * (1 - m) ** 2 * m * x1 + 3 * (1 - m) * m * m * x2 + m ** 3
        lo, hi = (m, hi) if x < t else (lo, m)
    m = (lo + hi) / 2
    return 3 * (1 - m) ** 2 * m * y1 + 3 * (1 - m) * m * m * y2 + m ** 3


def _first(v, d):
    if v is None:
        return d
    return v[0] if isinstance(v, list) else v


def _lerp(a, b, u):
    if isinstance(a, dict):
        return {k: (_lerp(a[k], b[k], u) if k != "c" else a[k]) for k in a}
    if isinstance(a, list):
        return [_lerp(x, y, u) for x, y in zip(a, b)]
    return a + (b - a) * u


def val(prop, f):
    if prop is None:
        return None
    if not prop.get("a"):
        return prop["k"]
    ks = prop["k"]
    if f <= ks[0]["t"]:
        v = ks[0]["s"]
    elif f >= ks[-1]["t"]:
        last = ks[-1]
        v = last.get("s", ks[-2].get("e"))
    else:
        for a, b in zip(ks, ks[1:]):
            if a["t"] <= f < b["t"]:
                u = (f - a["t"]) / (b["t"] - a["t"])
                if "o" in a and "i" in a:
                    u = _bez(u, _first(a["o"]["x"], 0), _first(a["o"]["y"], 0),
                             _first(a["i"]["x"], 1), _first(a["i"]["y"], 1))
                v = _lerp(a["s"], b.get("s", a.get("e")), u)
                break
    if isinstance(v, list) and len(v) == 1 and isinstance(v[0], dict):
        return v[0]
    return v


def num(prop, f, d):
    v = val(prop, f)
    if v is None:
        return d
    return v[0] if isinstance(v, list) and len(v) == 1 else v


# ---------- матрицы ----------
def mat(p=(0, 0), a=(0, 0), s=(100, 100), r=0.0):
    c, sn = math.cos(math.radians(r)), math.sin(math.radians(r))
    sx, sy = s[0] / 100, s[1] / 100
    T = np.array([[1, 0, p[0]], [0, 1, p[1]], [0, 0, 1]], float)
    R = np.array([[c, -sn, 0], [sn, c, 0], [0, 0, 1]], float)
    S = np.diag([sx, sy, 1.0])
    A = np.array([[1, 0, -a[0]], [0, 1, -a[1]], [0, 0, 1]], float)
    return T @ R @ S @ A


def tr_mat(t, f):
    p = val(t.get("p"), f) or [0, 0]
    a = val(t.get("a"), f) or [0, 0]
    s = val(t.get("s"), f) or [100, 100]
    r = num(t.get("r"), f, 0)
    o = num(t.get("o"), f, 100)
    return mat(p[:2], a[:2], s[:2], r), o / 100


# ---------- геометрия ----------
def path_pts(sh, n=16):
    v, ii, oo = sh["v"], sh["i"], sh["o"]
    out = []
    cnt = len(v) if sh.get("c", True) else len(v) - 1
    for k in range(cnt):
        p0 = v[k]; p3 = v[(k + 1) % len(v)]
        c1 = (p0[0] + oo[k][0], p0[1] + oo[k][1])
        c2 = (p3[0] + ii[(k + 1) % len(v)][0], p3[1] + ii[(k + 1) % len(v)][1])
        for s in range(n):
            t = s / n; u = 1 - t
            out.append((u ** 3 * p0[0] + 3 * u * u * t * c1[0] + 3 * u * t * t * c2[0] + t ** 3 * p3[0],
                        u ** 3 * p0[1] + 3 * u * u * t * c1[1] + 3 * u * t * t * c2[1] + t ** 3 * p3[1]))
    return out


def rc_pts(it, f):
    cx, cy = val(it["p"], f); w, h = val(it["s"], f)
    r = min(num(it.get("r"), f, 0), w / 2, h / 2)
    pts = []
    for (ox, oy, a0) in ((w / 2 - r, -h / 2 + r, -90), (w / 2 - r, h / 2 - r, 0),
                         (-w / 2 + r, h / 2 - r, 90), (-w / 2 + r, -h / 2 + r, 180)):
        for s in range(10):
            ang = math.radians(a0 + 90 * s / 9)
            pts.append((cx + ox + r * math.cos(ang), cy + oy + r * math.sin(ang)))
    return pts


def el_pts(it, f):
    cx, cy = val(it["p"], f); w, h = val(it["s"], f)
    return [(cx + w / 2 * math.cos(2 * math.pi * k / 48), cy + h / 2 * math.sin(2 * math.pi * k / 48))
            for k in range(48)]


def sr_pts(it, f):
    cx, cy = val(it["p"], f)
    n = int(num(it["pt"], f, 5)); orr = num(it["or"], f, 10)
    irr = num(it.get("ir"), f, orr / 2); rot = num(it.get("r"), f, 0)
    star = it.get("sy", 1) == 1
    pts = []
    steps = n * 2 if star else n
    for k in range(steps):
        rr = orr if (not star or k % 2 == 0) else irr
        ang = math.radians(rot - 90 + 360 * k / steps)
        pts.append((cx + rr * math.cos(ang), cy + rr * math.sin(ang)))
    return pts


def apply(M, pts):
    return [((M[0, 0] * x + M[0, 1] * y + M[0, 2]) * SS, (M[1, 0] * x + M[1, 1] * y + M[1, 2]) * SS)
            for x, y in pts]


# ---------- заливки ----------
def grad_img(gf, f, M, W, H):
    g = gf["g"]; p = g["p"]; k = val(g["k"], f)
    cols = [(k[4 * i], k[4 * i + 1:4 * i + 4]) for i in range(p)]
    ops = [(k[4 * p + 2 * i], k[4 * p + 2 * i + 1]) for i in range((len(k) - 4 * p) // 2)]
    s = apply(M, [val(gf["s"], f)[:2]])[0]; e = apply(M, [val(gf["e"], f)[:2]])[0]
    yy, xx = np.mgrid[0:H, 0:W].astype(float)
    if gf.get("t", 1) == 1:
        dx, dy = e[0] - s[0], e[1] - s[1]
        u = ((xx - s[0]) * dx + (yy - s[1]) * dy) / max(dx * dx + dy * dy, 1e-6)
    else:
        u = np.hypot(xx - s[0], yy - s[1]) / max(math.hypot(e[0] - s[0], e[1] - s[1]), 1e-6)
    u = np.clip(u, 0, 1)
    rgb = np.stack([np.interp(u, [c[0] for c in cols], [c[1][j] for c in cols]) for j in range(3)], -1)
    a = np.interp(u, [o[0] for o in ops], [o[1] for o in ops]) if ops else np.ones_like(u)
    return rgb, a


def render_frame(anim, f, size=None, bg=None):
    W, H = anim["w"] * SS, anim["h"] * SS
    canvas = np.zeros((H, W, 4), float)
    if bg:
        canvas[..., :3] = np.array(bg) / 255; canvas[..., 3] = 1
    layers = anim["layers"]
    by_ind = {l["ind"]: l for l in layers}

    def lmat(l):
        ks = l["ks"]
        M, _ = tr_mat(ks, f)
        if "parent" in l:
            M = lmat(by_ind[l["parent"]]) @ M
        return M

    def draw(pts, rgb, alpha, opacity):
        if len(pts) < 3:
            return
        m = Image.new("L", (W, H), 0)
        ImageDraw.Draw(m).polygon(pts, fill=255)
        mk = np.asarray(m, float) / 255 * alpha * opacity
        mk = mk[..., None]
        canvas[..., :3] = canvas[..., :3] * (1 - mk) + rgb * mk
        canvas[..., 3:] = canvas[..., 3:] * (1 - mk) + mk

    def group(items, M, op):
        geo, fill = [], None
        t = next((i for i in items if i["ty"] == "tr"), None)
        if t:
            GM, go = tr_mat(t, f); M = M @ GM; op *= go
        for it in reversed(items):
            if it["ty"] == "gr":
                group(it["it"], M, op)
        for it in items:
            ty = it["ty"]
            if ty == "sh":
                geo.append(path_pts(val(it["ks"], f)))
            elif ty == "rc":
                geo.append(rc_pts(it, f))
            elif ty == "el":
                geo.append(el_pts(it, f))
            elif ty == "sr":
                geo.append(sr_pts(it, f))
            elif ty in ("fl", "gf") and fill is None:
                fill = it
        if not fill:
            return
        fo = num(fill.get("o"), f, 100) / 100
        for g in geo:
            pts = apply(M, g)
            if fill["ty"] == "fl":
                c = val(fill["c"], f)
                draw(pts, np.array(c[:3]), 1.0, op * fo)
            else:
                rgb, a = grad_img(fill, f, M, W, H)
                draw(pts, rgb, a, op * fo)

    for l in reversed(layers):
        if l["ty"] != 4 or not (l.get("ip", 0) <= f < l.get("op", 1e9)):
            continue
        o = num(l["ks"].get("o"), f, 100) / 100
        if o <= 0:
            continue
        group(l["shapes"], lmat(l), o)

    img = Image.fromarray((np.clip(canvas, 0, 1) * 255).astype(np.uint8), "RGBA")
    img = img.resize((size or anim["w"],) * 2, Image.LANCZOS)
    return img


def main():
    src, out = sys.argv[1], sys.argv[2]
    anim = json.load(open(src))
    bg = (255, 255, 255)
    if "--frames" in sys.argv:
        frames = [int(x) for x in sys.argv[sys.argv.index("--frames") + 1].split(",")]
        ims = [render_frame(anim, fr, 300, bg).convert("RGB") for fr in frames]
        strip = Image.new("RGB", (300 * len(ims), 300), bg)
        for i, im in enumerate(ims):
            strip.paste(im, (300 * i, 0))
        strip.save(out)
    else:
        step = 2
        ims = [render_frame(anim, fr, 256, bg).convert("RGB")
               for fr in range(anim["ip"], anim["op"], step)]
        ims[0].save(out, save_all=True, append_images=ims[1:], loop=0,
                    duration=int(1000 * step / anim["fr"]))


if __name__ == "__main__":
    main()
