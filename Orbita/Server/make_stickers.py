"""
Генератор стикеров Orbita (оригинальные рисунки, рисуются кодом через Pillow).
Запуск:  python3 make_stickers.py   → Server/stickers/<пак>/<имя>.png и packs.json
Обычному запуску сервера он не нужен: готовые PNG уже лежат в папке stickers.
"""
import json
import math
import os

from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont

S = 1024                      # рисуем крупно и уменьшаем — гладкие края
OUT = 512
HERE = os.path.dirname(os.path.abspath(__file__))
FONT = "/usr/share/fonts/opentype/noto/NotoSansCJK-Black.ttc"

INK = (38, 36, 66, 255)
WHITE = (255, 255, 255, 255)


def font(size):
    for path in (FONT, "/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc",
                 "/usr/share/fonts/truetype/dejavu/DejaVuSans-Bold.ttf"):
        if os.path.exists(path):
            return ImageFont.truetype(path, size)
    return ImageFont.load_default()


def canvas():
    img = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    return img, ImageDraw.Draw(img)


def shade(c, k):
    return tuple(max(0, min(255, int(v * k))) for v in c[:3]) + (255,)


def circle(d, cx, cy, r, fill, outline=None, w=0):
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=fill, outline=outline, width=w)


def eyes(d, cx, cy, gap, r, kind="dot"):
    for sx in (-1, 1):
        x = cx + sx * gap
        if kind == "dot":
            circle(d, x, cy, r, INK)
            circle(d, x - r * 0.3, cy - r * 0.3, r * 0.32, WHITE)
        elif kind == "happy":                      # ^ ^
            d.arc([x - r, cy - r * 0.6, x + r, cy + r * 1.4], 200, 340, fill=INK, width=int(r * 0.7))
        elif kind == "closed":
            d.arc([x - r, cy - r, x + r, cy + r], 20, 160, fill=INK, width=int(r * 0.6))
        elif kind == "wow":
            circle(d, x, cy, r * 1.15, WHITE, INK, int(r * 0.35))
            circle(d, x, cy, r * 0.5, INK)
        elif kind == "heart":
            heart(d, x, cy, r * 1.5, (236, 64, 100, 255))


def mouth(d, cx, cy, w, kind="smile"):
    t = int(w * 0.16)
    if kind == "smile":
        d.arc([cx - w, cy - w * 0.7, cx + w, cy + w * 0.7], 20, 160, fill=INK, width=t)
    elif kind == "open":
        d.pieslice([cx - w, cy - w * 0.5, cx + w, cy + w * 0.9], 0, 180, fill=INK)
        d.pieslice([cx - w * 0.55, cy + w * 0.12, cx + w * 0.55, cy + w * 0.8], 0, 180, fill=(240, 98, 120, 255))
    elif kind == "o":
        circle(d, cx, cy + w * 0.2, w * 0.38, INK)
    elif kind == "sad":
        d.arc([cx - w, cy, cx + w, cy + w * 1.3], 200, 340, fill=INK, width=t)
    elif kind == "flat":
        d.rounded_rectangle([cx - w * 0.7, cy, cx + w * 0.7, cy + t], radius=t // 2, fill=INK)


def cheeks(d, cx, cy, gap, r):
    for sx in (-1, 1):
        circle(d, cx + sx * gap, cy, r, (255, 120, 140, 130))


def heart(d, cx, cy, r, fill):
    pts = []
    for i in range(0, 361, 4):
        t = math.radians(i)
        x = 16 * math.sin(t) ** 3
        y = -(13 * math.cos(t) - 5 * math.cos(2 * t) - 2 * math.cos(3 * t) - math.cos(4 * t))
        pts.append((cx + x * r / 17, cy + y * r / 17))
    d.polygon(pts, fill=fill)


def star(d, cx, cy, r, fill, inner=0.5):
    pts = []
    for i in range(10):
        a = math.radians(-90 + i * 36)
        rr = r if i % 2 == 0 else r * inner
        pts.append((cx + rr * math.cos(a), cy + rr * math.sin(a)))
    d.polygon(pts, fill=fill, outline=shade(fill, 0.8))


def rounded_star(img, cx, cy, r, fill):
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    star(ImageDraw.Draw(layer), cx, cy, r, fill, 0.55)
    layer = layer.filter(ImageFilter.GaussianBlur(14))
    a = layer.split()[3].point(lambda v: 255 if v > 110 else 0)
    solid = Image.new("RGBA", (S, S), fill)
    img.paste(solid, (0, 0), a)


def sparkle(d, cx, cy, r, fill=(255, 236, 140, 255)):
    d.polygon([(cx, cy - r), (cx + r * 0.22, cy - r * 0.22), (cx + r, cy), (cx + r * 0.22, cy + r * 0.22),
               (cx, cy + r), (cx - r * 0.22, cy + r * 0.22), (cx - r, cy), (cx - r * 0.22, cy - r * 0.22)], fill=fill)


def finish(img, name_dir, name):
    """Белая обводка (как у настоящих стикеров) + мягкая тень, уменьшение и сохранение"""
    alpha = img.split()[3]
    grow = alpha.filter(ImageFilter.MaxFilter(31)).filter(ImageFilter.GaussianBlur(3))
    grow = grow.point(lambda v: 255 if v > 90 else 0)
    outline = Image.new("RGBA", (S, S), (255, 255, 255, 255))
    outline.putalpha(grow)
    shadow = Image.new("RGBA", (S, S), (20, 20, 50, 90))
    shadow.putalpha(grow.filter(ImageFilter.GaussianBlur(14)).point(lambda v: int(v * 0.35)))
    out = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    out.alpha_composite(shadow, (0, 14))
    out.alpha_composite(outline)
    out.alpha_composite(img)
    box = out.getbbox()
    if box:
        pad = 18
        box = (max(0, box[0] - pad), max(0, box[1] - pad), min(S, box[2] + pad), min(S, box[3] + pad))
        out = out.crop(box)
    w, h = out.size
    k = (OUT - 8) / max(w, h)
    out = out.resize((max(1, int(w * k)), max(1, int(h * k))), Image.LANCZOS)
    final = Image.new("RGBA", (OUT, OUT), (0, 0, 0, 0))
    final.alpha_composite(out, ((OUT - out.width) // 2, (OUT - out.height) // 2))
    os.makedirs(name_dir, exist_ok=True)
    final.save(os.path.join(name_dir, name + ".png"), optimize=True)
    return final


# ---------------------------------------------------------------- Космос

def planet():
    img, d = canvas()
    cx, cy, r = 512, 520, 300
    ring_back = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    rb = ImageDraw.Draw(ring_back)
    rb.ellipse([cx - 440, cy - 110, cx + 440, cy + 110], outline=(255, 214, 120, 255), width=46)
    img.alpha_composite(ring_back)
    circle(d, cx, cy, r, (122, 108, 240, 255))
    d.pieslice([cx - r, cy - r, cx + r, cy + r], 200, 330, fill=(150, 136, 255, 255))
    circle(d, cx + 120, cy + 140, 60, (104, 90, 224, 255))
    circle(d, cx - 150, cy + 150, 34, (104, 90, 224, 255))
    front = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ImageDraw.Draw(front).arc([cx - 440, cy - 110, cx + 440, cy + 110], 0, 180, fill=(255, 214, 120, 255), width=46)
    img.alpha_composite(front)
    d = ImageDraw.Draw(img)
    eyes(d, cx, cy - 20, 90, 34)
    mouth(d, cx, cy + 40, 70, "open")
    cheeks(d, cx, cy + 50, 155, 28)
    sparkle(d, 150, 170, 60)
    sparkle(d, 880, 250, 40)
    return img


def rocket():
    img, d = canvas()
    cx = 512
    flame = [(cx - 90, 760), (cx, 960), (cx + 90, 760)]
    d.polygon(flame, fill=(255, 150, 60, 255))
    d.polygon([(cx - 50, 760), (cx, 900), (cx + 50, 760)], fill=(255, 220, 110, 255))
    for sx in (-1, 1):
        d.polygon([(cx + sx * 130, 520), (cx + sx * 290, 760), (cx + sx * 130, 730)], fill=(236, 76, 110, 255))
    d.ellipse([cx - 160, 90, cx + 160, 800], fill=(246, 248, 255, 255))
    d.pieslice([cx - 160, 90, cx + 160, 600], 180, 360, fill=(246, 248, 255, 255))
    d.chord([cx - 160, 80, cx + 160, 520], 180, 360, fill=(236, 76, 110, 255))
    d.rectangle([cx - 160, 300, cx + 160, 330], fill=(228, 232, 246, 255))
    circle(d, cx, 460, 92, (90, 112, 240, 255), (60, 74, 170, 255), 18)
    circle(d, cx, 460, 62, (140, 214, 255, 255))
    circle(d, cx - 20, 442, 14, WHITE)
    d.rounded_rectangle([cx - 100, 660, cx + 100, 700], radius=20, fill=(228, 232, 246, 255))
    sparkle(d, 160, 220, 56)
    sparkle(d, 860, 560, 44)
    return img


def astro():
    img, d = canvas()
    cx, cy = 512, 540
    d.rounded_rectangle([cx - 220, cy + 120, cx + 220, cy + 400], radius=110, fill=(240, 244, 252, 255))
    circle(d, cx - 210, cy + 250, 70, (240, 244, 252, 255))
    circle(d, cx + 230, cy + 130, 70, (240, 244, 252, 255))
    d.rounded_rectangle([cx - 90, cy + 220, cx + 90, cy + 300], radius=24, fill=(120, 130, 230, 255))
    circle(d, cx, cy - 60, 290, (240, 244, 252, 255))
    circle(d, cx, cy - 50, 215, (46, 52, 110, 255))
    d.pieslice([cx - 215, cy - 265, cx + 215, cy + 165], 200, 280, fill=(80, 90, 170, 255))
    eyes(d, cx, cy - 55, 70, 26)
    mouth(d, cx, cy + 15, 55, "smile")
    cheeks(d, cx, cy + 10, 120, 22)
    circle(d, cx + 130, cy - 170, 28, (255, 255, 255, 90))
    d.rounded_rectangle([cx - 40, cy + 330, cx + 40, cy + 360], radius=14, fill=(236, 76, 110, 255))
    sparkle(d, 140, 150, 56)
    return img


def star_happy():
    img, d = canvas()
    rounded_star(img, 512, 540, 440, (255, 205, 60, 255))
    d = ImageDraw.Draw(img)
    eyes(d, 512, 520, 85, 32)
    mouth(d, 512, 585, 66, "open")
    cheeks(d, 512, 580, 150, 28)
    return img


def moon():
    img, d = canvas()
    cx, cy = 480, 520
    circle(d, cx, cy, 380, (255, 226, 130, 255))
    circle(d, cx + 190, cy - 100, 330, (0, 0, 0, 0))
    mask = Image.new("L", (S, S), 255)
    ImageDraw.Draw(mask).ellipse([cx + 190 - 330, cy - 100 - 330, cx + 190 + 330, cy - 100 + 330], fill=0)
    base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    bd = ImageDraw.Draw(base)
    bd.ellipse([cx - 380, cy - 380, cx + 380, cy + 380], fill=(255, 226, 130, 255))
    base.putalpha(ImageChops.multiply(base.split()[3], mask))
    img = base
    d = ImageDraw.Draw(img)
    circle(d, 250, 560, 48, (240, 200, 100, 255))
    circle(d, 330, 330, 30, (240, 200, 100, 255))
    eyes(d, 300, 470, 0, 0)
    d.arc([230, 430, 340, 500], 20, 160, fill=INK, width=18)
    mouth(d, 270, 640, 44, "smile")
    t = font(150)
    d.text((620, 190), "Z", font=t, fill=(140, 150, 255, 255))
    d.text((760, 90), "z", font=font(100), fill=(140, 150, 255, 255))
    sparkle(d, 800, 650, 56)
    return img


def ufo():
    img, d = canvas()
    cx = 512
    d.polygon([(cx - 120, 640), (cx - 300, 960), (cx + 300, 960), (cx + 120, 640)], fill=(255, 240, 160, 110))
    d.pieslice([cx - 200, 180, cx + 200, 640], 180, 360, fill=(150, 220, 255, 230), outline=(110, 180, 230, 255), width=14)
    circle(d, cx, 410, 52, (110, 214, 140, 255))
    eyes(d, cx, 400, 20, 10)
    d.ellipse([cx - 400, 420, cx + 400, 680], fill=(150, 156, 235, 255))
    d.chord([cx - 400, 420, cx + 400, 680], 0, 180, fill=(120, 126, 215, 255))
    for i, x in enumerate((-250, -90, 90, 250)):
        circle(d, cx + x, 560 + (0 if abs(x) < 200 else -14), 30, [(255, 214, 100, 255), (255, 120, 160, 255)][i % 2])
    sparkle(d, 140, 200, 50)
    sparkle(d, 890, 160, 36)
    return img


def comet():
    img, d = canvas()
    tail = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    td = ImageDraw.Draw(tail)
    hc = (650, 450)
    tip = (90, 900)
    dx, dy = tip[0] - hc[0], tip[1] - hc[1]
    ln = math.hypot(dx, dy)
    px, py = -dy / ln, dx / ln
    for k, col in ((1.0, (255, 150, 90, 255)), (0.7, (255, 205, 120, 255)), (0.4, (255, 240, 180, 255))):
        rr = 270 * k
        td.polygon([(hc[0] + px * rr, hc[1] + py * rr), tip, (hc[0] - px * rr, hc[1] - py * rr)], fill=col)
    img.alpha_composite(tail)
    d = ImageDraw.Draw(img)
    circle(d, 650, 450, 270, (255, 190, 80, 255))
    circle(d, 650, 450, 270, (255, 190, 80, 255))
    d.pieslice([380, 180, 920, 720], 190, 300, fill=(255, 214, 120, 255))
    eyes(d, 680, 430, 85, 32)
    mouth(d, 680, 500, 62, "open")
    cheeks(d, 680, 500, 150, 26)
    sparkle(d, 840, 150, 50)
    return img


def earth():
    img, d = canvas()
    cx, cy, r = 512, 520, 400
    circle(d, cx, cy, r, (70, 150, 240, 255))
    land = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(land)
    ld.ellipse([250, 250, 520, 480], fill=(96, 200, 120, 255))
    ld.ellipse([500, 620, 800, 800], fill=(96, 200, 120, 255))
    ld.ellipse([620, 280, 780, 420], fill=(96, 200, 120, 255))
    mask = Image.new("L", (S, S), 0)
    ImageDraw.Draw(mask).ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    land.putalpha(ImageChops.multiply(land.split()[3], mask))
    img.alpha_composite(land)
    d = ImageDraw.Draw(img)
    d.arc([cx - r + 30, cy - r + 30, cx + r - 30, cy + r - 30], 205, 245, fill=(255, 255, 255, 150), width=26)
    eyes(d, cx, cy + 10, 100, 36)
    mouth(d, cx, cy + 90, 72, "open")
    cheeks(d, cx, cy + 90, 175, 30)
    return img


# ---------------------------------------------------------------- Реакции

def face(d, cx, cy, r, base=(255, 205, 70, 255)):
    circle(d, cx, cy, r, base)
    d.pieslice([cx - r, cy - r, cx + r, cy + r], 200, 300, fill=shade(base, 1.07))
    d.arc([cx - r, cy - r, cx + r, cy + r], 0, 360, fill=shade(base, 0.82), width=14)


def like():
    img, d = canvas()
    skin = (255, 200, 80, 255)
    d.rounded_rectangle([140, 470, 330, 900], radius=50, fill=(90, 120, 240, 255))
    d.rounded_rectangle([340, 470, 820, 900], radius=70, fill=skin, outline=shade(skin, 0.8), width=14)
    for i, y in enumerate((590, 690, 790)):
        d.rounded_rectangle([420 + i * 14, y, 800 - i * 6, y + 78], radius=39, fill=skin, outline=shade(skin, 0.8), width=12)
    d.rounded_rectangle([340, 160, 520, 560], radius=88, fill=skin, outline=shade(skin, 0.8), width=14)
    d.rounded_rectangle([340, 430, 560, 620], radius=60, fill=skin)
    circle(d, 235, 700, 28, (60, 80, 190, 255))
    sparkle(d, 760, 190, 70)
    sparkle(d, 880, 360, 40)
    return img


def heart_face():
    img, d = canvas()
    heart(d, 512, 500, 470, (240, 70, 110, 255))
    layer = Image.new("RGBA", (S, S), (0, 0, 0, 0))
    ld = ImageDraw.Draw(layer)
    ld.ellipse([300, 320, 410, 385], fill=(255, 160, 185, 200))
    img.alpha_composite(layer)
    d = ImageDraw.Draw(img)
    eyes(d, 512, 480, 100, 36)
    mouth(d, 512, 560, 70, "smile")
    cheeks(d, 512, 560, 190, 30)
    return img


def laugh():
    img, d = canvas()
    face(d, 512, 520, 400)
    for sx in (-1, 1):
        x = 512 + sx * 150
        d.arc([x - 70, 400, x + 70, 540], 200, 340, fill=INK, width=34)
        d.ellipse([x + sx * 60 - 28, 520, x + sx * 60 + 28, 640], fill=(120, 200, 255, 255))
    d.pieslice([512 - 230, 520 - 60, 512 + 230, 520 + 270], 0, 180, fill=INK)
    d.pieslice([512 - 120, 520 + 110, 512 + 120, 520 + 280], 0, 180, fill=(240, 98, 120, 255))
    d.rectangle([512 - 190, 520 + 50, 512 + 190, 520 + 110], fill=WHITE)
    d.pieslice([512 - 230, 520 - 60, 512 + 230, 520 + 270], 0, 180, outline=INK, width=22)
    return img


def cool():
    img, d = canvas()
    face(d, 512, 520, 400)
    d.rounded_rectangle([190, 400, 470, 560], radius=60, fill=INK)
    d.rounded_rectangle([554, 400, 834, 560], radius=60, fill=INK)
    d.rectangle([450, 430, 574, 460], fill=INK)
    d.polygon([(215, 420), (300, 420), (240, 500)], fill=(255, 255, 255, 90))
    d.polygon([(580, 420), (665, 420), (605, 500)], fill=(255, 255, 255, 90))
    mouth(d, 512, 650, 120, "smile")
    return img


def sad():
    img, d = canvas()
    face(d, 512, 520, 400)
    eyes(d, 512, 480, 130, 36)
    d.polygon([(330, 400), (420, 360), (420, 395)], fill=INK)
    d.polygon([(694, 400), (604, 360), (604, 395)], fill=INK)
    mouth(d, 512, 680, 110, "sad")
    for sx in (-1, 1):
        d.ellipse([512 + sx * 150 - 30, 540, 512 + sx * 150 + 30, 700], fill=(120, 200, 255, 255))
    return img


def love():
    img, d = canvas()
    face(d, 512, 520, 400)
    eyes(d, 512, 470, 135, 40, "heart")
    mouth(d, 512, 600, 100, "open")
    cheeks(d, 512, 590, 235, 36)
    heart(d, 800, 170, 150, (240, 70, 110, 255))
    heart(d, 230, 140, 90, (255, 130, 160, 255))
    return img


def wow():
    img, d = canvas()
    face(d, 512, 540, 400)
    eyes(d, 512, 480, 125, 50, "wow")
    d.ellipse([452, 620, 572, 780], fill=INK)
    d.arc([260, 330, 400, 380], 200, 340, fill=INK, width=22)
    d.arc([624, 330, 764, 380], 200, 340, fill=INK, width=22)
    sparkle(d, 860, 200, 56)
    return img


def text_sticker(text, color, size, tilt=-6):
    def make():
        img, d = canvas()
        bubble = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        bd = ImageDraw.Draw(bubble)
        bd.rounded_rectangle([60, 260, 964, 700], radius=200, fill=color)
        bd.polygon([(220, 650), (160, 860), (400, 690)], fill=color)
        bd.rounded_rectangle([60, 260, 964, 360], radius=100, fill=shade(color, 1.1))
        bubble = bubble.rotate(tilt, resample=Image.BICUBIC, center=(512, 512))
        img.alpha_composite(bubble)
        d = ImageDraw.Draw(img)
        f = font(size)
        w = d.textlength(text, font=f)
        txt = Image.new("RGBA", (S, S), (0, 0, 0, 0))
        td = ImageDraw.Draw(txt)
        td.text(((S - w) / 2, 330), text, font=f, fill=WHITE, stroke_width=0)
        txt = txt.rotate(tilt, resample=Image.BICUBIC, center=(512, 512))
        img.alpha_composite(txt)
        return img
    return make


PACKS = [
    {"id": "cosmos", "title": "Космос", "icon": "planet", "items": [
        ("planet", planet, "🪐"), ("rocket", rocket, "🚀"), ("astro", astro, "👨‍🚀"), ("star", star_happy, "⭐"),
        ("moon", moon, "🌙"), ("ufo", ufo, "🛸"), ("comet", comet, "☄️"), ("earth", earth, "🌍")]},
    {"id": "mood", "title": "Реакции", "icon": "like", "items": [
        ("like", like, "👍"), ("heart", heart_face, "❤️"), ("laugh", laugh, "😂"), ("cool", cool, "😎"),
        ("sad", sad, "😢"), ("love", love, "😍"), ("wow", wow, "😮"),
        ("privet", text_sticker("ПРИВЕТ", (110, 130, 250, 255), 190), "👋"),
        ("ok", text_sticker("ОК", (70, 190, 130, 255), 330, 5), "👌"),
        ("spasibo", text_sticker("СПС", (240, 120, 150, 255), 270, -4), "🙏")]},
]


def main():
    manifest = []
    for pack in PACKS:
        folder = os.path.join(HERE, "stickers", pack["id"])
        stickers = []
        for name, fn, emoji in pack["items"]:
            finish(fn(), folder, name)
            stickers.append({"id": name, "emoji": emoji})
        manifest.append({"id": pack["id"], "title": pack["title"], "icon": pack["icon"], "stickers": stickers})
    with open(os.path.join(HERE, "stickers", "packs.json"), "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print("Готово:", sum(len(p["stickers"]) for p in manifest), "стикеров")


if __name__ == "__main__":
    main()
