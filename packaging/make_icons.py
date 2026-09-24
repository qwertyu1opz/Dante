#!/usr/bin/env python3
import os
from PIL import Image, ImageDraw, ImageFilter

SRC = os.path.expanduser('~/Desktop/dante')
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'Dante', 'Resources')
SIZES = {
    'Icon.png': 57, 'Icon@2x.png': 114,
    'Icon-72.png': 72, 'Icon-72@2x.png': 144,
    'Icon-Small.png': 29, 'Icon-Small@2x.png': 58,
    'Icon-Small-50.png': 50, 'Icon-Small-50@2x.png': 100,
}
RADIUS = 0.175


def load_art():
    img = Image.open(SRC).convert('RGB')
    w, h = img.size
    gray = img.convert('L')
    px = gray.load()

    def row_mean(y):
        return sum(px[x, y] for x in range(w)) / w

    top = next(y for y in range(h) if row_mean(y) > 30)
    bottom = next(y for y in range(h - 1, -1, -1) if row_mean(y) > 30)
    top, bottom = top + 3, bottom - 3
    side = bottom - top + 1
    left = max(0, min(w - side, 16))
    return img.crop((left, top, left + side, top + side))


ART = load_art()


def render(side):
    s = side * 4
    art = ART.resize((s, s), Image.LANCZOS).convert('RGBA')

    gloss = Image.new('L', (s, s), 0)
    d = ImageDraw.Draw(gloss)
    d.ellipse((-s * 0.35, -s * 0.62, s * 1.35, s * 0.52), fill=255)
    fade = Image.linear_gradient('L').resize((s, s)).point(lambda v: int(255 - v * 0.9))
    gloss = Image.composite(fade, Image.new('L', (s, s), 0), gloss).point(lambda v: int(v * 0.42))
    art = Image.composite(Image.new('RGBA', (s, s), (255, 255, 255, 255)), art, gloss)

    mask = Image.new('L', (s, s), 0)
    ImageDraw.Draw(mask).rounded_rectangle((0, 0, s - 1, s - 1), radius=int(s * RADIUS), fill=255)
    art.putalpha(mask)
    return art.resize((side, side), Image.LANCZOS)


for name, side in SIZES.items():
    render(side).save(os.path.join(OUT, name))
    print(name, side)

for name, side in {'DanteHeader.png': 96, 'DanteHeader@2x.png': 192}.items():
    ART.resize((side, side), Image.LANCZOS).save(os.path.join(OUT, name))
    print(name, side)

for name, (w, h) in {'Default.png': (320, 480), 'Default@2x.png': (640, 960),
                     'Default-568h@2x.png': (640, 1136)}.items():
    Image.new('RGB', (w, h), (0, 0, 0)).save(os.path.join(OUT, name))
    print(name, w, h)
