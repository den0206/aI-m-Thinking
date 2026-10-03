#!/usr/bin/env python3
"""App icon generator: hands tapping a keyboard, seen from the front-right.

Edit the CONFIG values below, then run `scripts/make-icon.sh` to rebuild
AppIcon.svg and app/Resources/AppIcon.icns.

Usage: generate_icon.py <out.svg>
"""
import math
import sys

# ---------------------------------------------------------------- CONFIG ----

COLORS = dict(
    bg_top="#F1E7D3", bg_bottom="#DCCDB0",  # icon background gradient
    shadow="#6B5A3E",                       # ground / hand shadows
    kb_front="#C9CDD6", kb_side="#B4B9C4", kb_top="#EEF0F4",
    key="#FFFFFF", key_face="#C3C8D2", key_side="#B7BCC7",
    key_hot="#A9C7EA", key_hot_face="#7E9CC2",  # key being pressed
    skin="#F3C6A5", skin_shade="#DDA07C",
    fx="#3B4656",                               # impact rings / tap lines
)

# Hands: (key column, key row, mirrored, lift px, tapping finger 0-3, extra rotation deg)
# mirrored=False is the far hand (top right), True is the near hand.
HANDS = [
    (12.2, 3.0, False, 70, 2, 4),
    (1.6, 2.8, True, 70, 1, -4),
]
HAND_SCALE = 0.66
HAND_SHADOW = False  # soft shadow cast by each hand onto the keyboard
HAND_ROTATION = 72  # degrees; fingers point toward the keyboard's back edge

ZOOM = 760          # keyboard bounding box is fitted into ZOOM x ZOOM px (of 1024)
CENTER = (512, 512)

# Keyboard projection: u = length, v = depth (front -> back), h = height
U = (0.26, -0.50)
V = (-0.98, -0.10)
O = (640, 800)
L, D = 680, 290
BODY_H = 44
COLS, ROWS = 13, 5
MU, MV = 28, 24     # key margins
KEY_FILL = 0.80     # key size relative to pitch

# ------------------------------------------------------------------------

DU, DV = (L - 2 * MU) / COLS, (D - 2 * MV) / ROWS
KEY_TOP = BODY_H + 14
FINGERS = [(-74, 6, 42), (-25, 30, 46), (25, 32, 46), (74, 12, 42)]  # x, tip y, width


def P(u, v, h=0):
    return (O[0] + u * U[0] + v * V[0], O[1] + u * U[1] + v * V[1] - h)


def unproject(x, y, h):
    bx, by = x - O[0], y - O[1] + h
    det = U[0] * V[1] - U[1] * V[0]
    return (bx * V[1] - by * V[0]) / det, (U[0] * by - U[1] * bx) / det


def poly(pts, fill, extra=""):
    s = " ".join(f"{x:.1f},{y:.1f}" for x, y in pts)
    return f'<polygon points="{s}" fill="{fill}" stroke="{fill}" stroke-width="2" stroke-linejoin="round"{extra}/>'


def capsule(x1, y1, x2, y2, w, fill):
    return f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{fill}" stroke-width="{w}" stroke-linecap="round"/>'


def keyboard(c, hot):
    H = BODY_H
    out = [
        poly([P(-10, -30), P(L + 30, -30), P(L + 30, D - 10), P(-10, D - 10)], c["shadow"], ' opacity="0.35"'),
        poly([P(0, 0, 0), P(L, 0, 0), P(L, 0, H), P(0, 0, H)], c["kb_front"]),
        poly([P(0, 0, 0), P(0, D, 0), P(0, D, H), P(0, 0, H)], c["kb_side"]),
        poly([P(0, 0, H), P(L, 0, H), P(L, D, H), P(0, D, H)], c["kb_top"]),
    ]
    t = 3
    # far keys first so nearer keys overlap them
    for ci in reversed(range(COLS)):
        for r in reversed(range(ROWS)):
            if r == 0 and 3 < ci < 9:
                continue  # covered by the space bar
            u0 = MU + ci * DU
            u1 = MU + 8 * DU + DU * KEY_FILL if (r, ci) == (0, 3) else u0 + DU * KEY_FILL
            v0 = MV + r * DV
            v1 = v0 + DV * KEY_FILL
            pressed = (r, ci) in hot
            kh = 4 if pressed else 14
            out.append(poly([P(u0, v0, H), P(u1, v0, H), P(u1 - t, v0 + t, H + kh), P(u0 + t, v0 + t, H + kh)],
                            c["key_hot_face"] if pressed else c["key_face"]))
            out.append(poly([P(u0, v0, H), P(u0, v1, H), P(u0 + t, v1 - t, H + kh), P(u0 + t, v0 + t, H + kh)], c["key_side"]))
            out.append(poly([P(u0 + t, v0 + t, H + kh), P(u1 - t, v0 + t, H + kh), P(u1 - t, v1 - t, H + kh), P(u0 + t, v1 - t, H + kh)],
                            c["key_hot"] if pressed else c["key"]))
    return out


def hand_shape(fill, dx=0, dy=0):
    o = [capsule(x * 0.9 + dx, -150 + dy, x + dx, ty - w / 2 + dy, w, fill) for x, ty, w in FINGERS]
    o.append(capsule(84 + dx, -220 + dy, 138 + dx, -96 + dy, 48, fill))  # thumb
    o.append(f'<rect x="{-100 + dx}" y="{-300 + dy}" width="200" height="180" rx="80" fill="{fill}"/>')  # back of hand
    return o


def impact(x, y, col):
    o = [f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="38" ry="16" fill="none" stroke="{col}" stroke-width="7" opacity="0.9" transform="rotate(-20 {x:.1f} {y:.1f})"/>',
         f'<ellipse cx="{x:.1f}" cy="{y:.1f}" rx="60" ry="26" fill="none" stroke="{col}" stroke-width="5" opacity="0.45" transform="rotate(-20 {x:.1f} {y:.1f})"/>']
    for a in (200, 235, 270, 305, 340):
        r = math.radians(a)
        o.append(f'<line x1="{x + 48 * math.cos(r):.1f}" y1="{y - 6 + 34 * math.sin(r):.1f}" x2="{x + 72 * math.cos(r):.1f}" y2="{y - 6 + 54 * math.sin(r):.1f}" '
                 f'stroke="{col}" stroke-width="11" stroke-linecap="round"/>')
    return o


def taps(x, y, col):
    return [f'<line x1="{x}" y1="{y + dy}" x2="{x}" y2="{y + dy + 16}" stroke="{col}" stroke-width="10" stroke-linecap="round" opacity="{op}"/>'
            for dy, op in ((0, 0.35), (28, 0.6), (56, 0.9))]


def build(c):
    S = HAND_SCALE
    hands, shadows, fx, hot = [], [], [], set()
    for ku, kv, mirror, lift, finger, drot in HANDS:
        u, v = MU + ku * DU, MV + kv * DV
        x, y = P(u, v, KEY_TOP)
        y -= lift
        r = HAND_ROTATION + drot
        a = math.radians(r)
        sx = -1 if mirror else 1
        # fingertip of the tapping finger, and the key straight below it
        fx_l = FINGERS[finger][0] * sx * S
        fy_l = (FINGERS[finger][1] + 4) * S
        tx, ty = x + fx_l * math.cos(a) - fy_l * math.sin(a), y + fx_l * math.sin(a) + fy_l * math.cos(a)
        kx, ky = tx, ty + lift - 6
        ku_, kv_ = unproject(kx, ky, KEY_TOP)
        hot.add((int((kv_ - MV) // DV), int((ku_ - MU) // DU)))

        hx, hy = P(u, v - 50, KEY_TOP)
        if HAND_SHADOW:
            shadows.append(f'<ellipse cx="{hx:.1f}" cy="{hy:.1f}" rx="110" ry="34" fill="{c["shadow"]}" opacity="0.22" transform="rotate(-18 {hx:.1f} {hy:.1f})"/>')
        g = hand_shape(c["skin_shade"], -8, 8) + hand_shape(c["skin"])
        hands.append(f'<g transform="translate({x:.1f} {y:.1f}) rotate({r:.1f}) scale({S * sx} {S})">' + "".join(g) + '</g>')
        fx += impact(kx, ky, c["fx"]) + taps(tx, ty + 18, c["fx"])

    pts = [P(0, 0, 0), P(L, 0, 0), P(0, D, 0), P(L, D, KEY_TOP), P(0, D, KEY_TOP)]
    x0, x1 = min(p[0] for p in pts), max(p[0] for p in pts)
    y0, y1 = min(p[1] for p in pts), max(p[1] for p in pts)
    sc = min(ZOOM / (x1 - x0), ZOOM / (y1 - y0))
    tx, ty = CENTER[0] - (x0 + x1) / 2 * sc, CENTER[1] - (y0 + y1) / 2 * sc

    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{c["bg_top"]}"/><stop offset="1" stop-color="{c["bg_bottom"]}"/></linearGradient>'
            '<clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="184"/></clipPath></defs>'
            '<rect x="100" y="100" width="824" height="824" rx="184" fill="url(#bg)"/>'
            '<g clip-path="url(#sq)">'
            f'<g transform="translate({tx:.1f} {ty:.1f}) scale({sc:.3f})">'
            + "".join(keyboard(c, hot) + shadows + fx + hands) +
            '</g></g></svg>\n')


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "w") as f:
        f.write(build(COLORS))
