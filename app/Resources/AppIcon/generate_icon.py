#!/usr/bin/env python3
"""App icon generator: the menu bar keycap, scaled up.

The keycap is built the same way as app/Sources/AImThinking/KeycapIcon.swift
(seen from the front-left and slightly above, base wider than the top face,
label sheared to follow the slant). Edit the CONFIG values below, then run
`scripts/make-icon.sh` to rebuild AppIcon.svg, app/Resources/AppIcon.icns and
docs/images/icon.png.

Usage: generate_icon.py <out.svg>
"""
import sys

# ---------------------------------------------------------------- CONFIG ----

LABEL = "thinking"

COLORS = dict(
    bg_top="#F7F7F9", bg_bottom="#E2E3E8",  # icon background gradient
    line="#141414",                         # keycap outline
    face="#FFFFFF",                         # top face
    shade="#000000",                        # front / side shading color
    front_alpha=0.25,                       # same shading as the menu bar icon
    side_alpha=0.55,
    text="#141414",
)
DROP_SHADOW = True  # soft shadow under the keycap

# Keycap geometry in px on the 1024 canvas (ratios follow KeycapIcon.swift)
FACE_WIDTH = 620    # top face width
SKEW = 54           # back edge shifted right: the view from the left
TAPER = 38          # base is wider than the top face
FACE_DEPTH = 168    # top face height
CAP_HEIGHT = 292    # top of the face to the base
LINE_WIDTH = 18
FONT_SIZE = 124
CENTER_Y = 530      # vertical center of the keycap

# ------------------------------------------------------------------------


def pts(points):
    return " ".join(f"{x:.1f},{y:.1f}" for x, y in points)


def keycap(c):
    W, K, T, FD = FACE_WIDTH, SKEW, TAPER, FACE_DEPTH
    left = 512 - (W + K + 2 * T) / 2 + T
    top = CENTER_Y - CAP_HEIGHT / 2
    base = top + CAP_HEIGHT

    back_left, back_right = (left + K, top), (left + W + K, top)
    front_right, front_left = (left + W, top + FD), (left, top + FD)
    base_front_left, base_front_right = (left - T, base), (left + W + T, base)
    base_back_right = (left + W + K + T, base - FD + 15)

    stroke = f'stroke="{c["line"]}" stroke-width="{LINE_WIDTH}" stroke-linejoin="round"'
    out = []
    if DROP_SHADOW:
        out.append(f'<polygon points="{pts([(base_front_left[0] + 10, base + 22), (base_front_right[0] + 22, base + 22), (base_back_right[0] + 22, base_back_right[1] + 22), base_back_right])}" fill="#000000" opacity="0.12"/>')
    out.append(f'<polygon points="{pts([front_left, front_right, base_front_right, base_front_left])}" fill="{c["shade"]}" fill-opacity="{c["front_alpha"]}" {stroke}/>')
    out.append(f'<polygon points="{pts([front_right, back_right, base_back_right, base_front_right])}" fill="{c["shade"]}" fill-opacity="{c["side_alpha"]}" {stroke}/>')
    out.append(f'<polygon points="{pts([back_left, back_right, front_right, front_left])}" fill="{c["face"]}" {stroke}/>')

    # Label on the top face, sheared to follow its slant.
    shear = -K / FD
    tx = K * (top + FD) / FD
    out.append(f'<g transform="matrix(1 0 {shear:.4f} 1 {tx:.1f} 0)">'
               f'<text x="{left + W / 2:.1f}" y="{top + FD / 2 + FONT_SIZE * 0.33:.1f}" text-anchor="middle" '
               f'font-family="-apple-system, Helvetica Neue, sans-serif" font-weight="600" font-size="{FONT_SIZE}" '
               f'fill="{c["text"]}">{LABEL}</text></g>')
    return out


def build(c):
    return ('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">'
            '<defs><linearGradient id="bg" x1="0" y1="0" x2="0" y2="1">'
            f'<stop offset="0" stop-color="{c["bg_top"]}"/><stop offset="1" stop-color="{c["bg_bottom"]}"/></linearGradient>'
            '<clipPath id="sq"><rect x="100" y="100" width="824" height="824" rx="184"/></clipPath></defs>'
            '<rect x="100" y="100" width="824" height="824" rx="184" fill="url(#bg)"/>'
            '<g clip-path="url(#sq)">' + "".join(keycap(c)) + '</g></svg>\n')


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    with open(sys.argv[1], "w") as f:
        f.write(build(COLORS))
