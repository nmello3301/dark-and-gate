# SPDX-License-Identifier: GPL-3.0-or-later
"""Slice the developer's flattened HUD art into layers (docs/design/hud.md).

    python tools/hud/slice.py            # writes tools/hud/out/*.png, preview.png,
                                         # and mod/.../data/hud_layout.lua

Sources (developer's own art, docs/design/hud/):
  hud-full-layout.png  2172x724: orbs, hotbar strip, potion slots, XP bar (high res)
  hud-asset-sheet.png  1536x1024: the 5 % orbs, used as the "empty" glass

Every piece keeps its position in the full-layout canvas, so the game can
recompose the art exactly: the layout file lists each piece's rectangle in
canvas pixels; the HUD scales the canvas to the screen.

Layers:
  orb_<h|m>_frame   the orb frame with the glass cut out (drawn last)
  orb_<h|m>_full    the glass full of liquid (circle)
  orb_<h|m>_empty   the empty glass (circle; the 5 % art with its sliver removed)
  meniscus_<h|m>    a soft bright line for the liquid's edge (generated)
  bar               the hotbar strip: 10 slots, both potion slots, XP track;
                    sword, flasks, digits, plate labels and XP fill removed
  slot_normal / slot_empty / slot_selected (selected = glow ring, hollow)
  potion_health / potion_mana   the flasks
  xp_fill / xp_cap  the XP fill body (stretched to the track) and its bright end
"""
import json
import os
import sys

import numpy as np
from PIL import Image, ImageDraw, ImageFilter
from scipy import ndimage

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SRC = os.path.join(ROOT, "docs", "design", "hud")
OUT = os.path.join(ROOT, "tools", "hud", "out")
LAYOUT_LUA = os.path.join(ROOT, "mod", "DarkAndGate", "Mods", "DarkAndGate", "ScriptExtender", "Lua", "data",
                          "hud_layout.lua")

# --- measurements in the source images (fitted by scripts/eye, 2026-10-12) ---
LAYOUT_W, LAYOUT_H = 2172, 724
ORB = {  # glass circle in the full layout: centre x, y, radius to the gold rim
    "h": (213, 518, 118),
    "m": (1959, 519, 118),
}
ORB_FRAME_BOX = {"h": (0, 270, 348, 690), "m": (1822, 270, 2172, 690)}
EMPTY_SRC = {"h": (668, 196, 75), "m": (1406, 197, 75)}  # asset sheet, 5 % orbs
GLASS_INSET = 2  # liquid circle radius = rim radius - inset

BAR_BOX = (344, 395, 1830, 672)
SLOT1_X, SLOT_PITCH, SLOT_Y0, SLOT_Y1, SLOT_W = 507, 116.33, 460, 576, 111
DIGIT_Y0, DIGIT_Y1 = 578, 607
POTION = {  # slot rect, flask rect, plate text rect
    "h": {"slot": (357, 450, 477, 594), "flask": (378, 470, 452, 575), "plate": (393, 578, 440, 604)},
    "m": {"slot": (1702, 450, 1814, 594), "flask": (1722, 470, 1794, 575), "plate": (1733, 578, 1784, 604)},
}
XP_TRACK = (462, 633, 1776, 650)  # x0, y0, x1, y1 (interior incl. border lines 632 / 650)
XP_FILL_END = 792                  # the art's fill ends here
XP_CAP_W = 30

DARK = 22  # background key threshold (max channel)


def load(name):
    return np.asarray(Image.open(os.path.join(SRC, name)).convert("RGB")).astype(np.float32)


def key_background(rgb, extra_bg=None):
    """RGBA from RGB: black connected to the crop border becomes transparent,
    with a soft edge (alpha from brightness in the dark band) and the black
    fringe removed (un-premultiplied)."""
    mx = rgb.max(axis=2)
    dark = mx < DARK
    lbl, _ = ndimage.label(dark, structure=np.ones((3, 3)))
    border = set(np.unique(np.concatenate([lbl[0], lbl[-1], lbl[:, 0], lbl[:, -1]]))) - {0}
    bg = np.isin(lbl, list(border))
    if extra_bg is not None:
        bg |= extra_bg
    alpha = np.ones(mx.shape, np.float32)
    soft = np.clip((mx - 4.0) / (DARK - 4.0), 0, 1)
    alpha[bg] = soft[bg]
    # a pixel deep inside the background is fully clear
    deep = ndimage.binary_erosion(bg, iterations=3, border_value=1)
    alpha[deep] = 0
    alpha = ndimage.gaussian_filter(alpha, 0.6)
    edge = np.zeros(mx.shape, bool)
    edge[:2], edge[-2:], edge[:, :2], edge[:, -2:] = True, True, True, True
    alpha[edge & bg] = 0
    a = np.clip(alpha, 1e-3, 1)[..., None]
    col = np.where(bg[..., None], np.clip(rgb / np.maximum(a, 0.35), 0, 255), rgb)
    return np.dstack([col, alpha * 255]).astype(np.uint8)


def circle_mask(h, w, cx, cy, r, feather=1.5):
    yy, xx = np.mgrid[0:h, 0:w].astype(np.float32)
    d = np.sqrt((xx - cx) ** 2 + (yy - cy) ** 2)
    return np.clip((r - d) / feather + 0.5, 0, 1)


def save(arr, name):
    os.makedirs(OUT, exist_ok=True)
    Image.fromarray(arr if arr.dtype == np.uint8 else arr.astype(np.uint8)).save(os.path.join(OUT, name + ".png"))


def fill_rows_from_edges(img, x0, y0, x1, y1, pad=3):
    """Replace a rect by, per row, the median of the pixels just outside its
    left and right edges (erases a digit on a smooth dark background)."""
    for y in range(y0, y1):
        ref = np.concatenate([img[y, x0 - pad:x0], img[y, x1:x1 + pad]])
        img[y, x0:x1] = np.median(ref, axis=0)


def main():
    L = load("hud-full-layout.png")
    A = load("hud-asset-sheet.png")
    layout = {"canvas": [LAYOUT_W, LAYOUT_H], "pieces": {}, "orbs": {}, "slots": [], "digits": [], "potions": {}}

    def piece(name, box):
        layout["pieces"][name] = [int(box[0]), int(box[1]), int(box[2] - box[0]), int(box[3] - box[1])]

    # --- orbs ---------------------------------------------------------------
    for k in ("h", "m"):
        cx, cy, r = ORB[k]
        x0, y0, x1, y1 = ORB_FRAME_BOX[k]
        crop = L[y0:y1, x0:x1].copy()
        hole = circle_mask(y1 - y0, x1 - x0, cx - x0, cy - y0, r - 1, feather=1.5) > 0.5
        rgba = key_background(crop)
        glass = circle_mask(y1 - y0, x1 - x0, cx - x0, cy - y0, r - 1, feather=1.5)
        rgba[..., 3] = (rgba[..., 3] * (1 - glass)).astype(np.uint8)
        save(rgba, "orb_%s_frame" % k)
        piece("orb_%s_frame" % k, ORB_FRAME_BOX[k])

        rg = r - GLASS_INSET
        size = 2 * rg + 2
        gx0, gy0 = cx - rg - 1, cy - rg - 1
        full = L[gy0:gy0 + size, gx0:gx0 + size].copy()
        m = circle_mask(size, size, size / 2, size / 2, rg, feather=1.2)
        save(np.dstack([full, m * 255]).astype(np.uint8), "orb_%s_full" % k)
        piece("orb_%s_full" % k, (gx0, gy0, gx0 + size, gy0 + size))
        piece("orb_%s_empty" % k, (gx0, gy0, gx0 + size, gy0 + size))

        ex, ey, er = EMPTY_SRC[k]
        ers = er - 1
        src = Image.fromarray(A[ey - ers:ey + ers, ex - ers:ex + ers].astype(np.uint8))
        e = np.asarray(src.resize((size, size), Image.LANCZOS)).astype(np.float32)
        # remove the 5 % liquid sliver: saturated pixels in the lower third -> dark glass
        yy = np.mgrid[0:size, 0:size][0]
        mx, mn = e.max(axis=2), e.min(axis=2)
        sat = (mx - mn) / np.maximum(mx, 1)
        sliver = (yy > size * 0.62) & (sat > 0.45) & (mx > 45)
        sliver = ndimage.binary_dilation(sliver, iterations=2)
        grey = (e.mean(axis=2, keepdims=True) * 0.35).repeat(3, axis=2)
        e = np.where(sliver[..., None], ndimage.gaussian_filter(grey, (2, 2, 0)), e)
        # the 5 % art glows with liquid colour along the rim: desaturate the outer ring
        yy2, xx2 = np.mgrid[0:size, 0:size]
        dist = np.sqrt((xx2 - size / 2) ** 2 + (yy2 - size / 2) ** 2) / rg
        w = np.clip((dist - 0.80) / 0.12, 0, 1)[..., None]
        lum = e.mean(axis=2, keepdims=True).repeat(3, axis=2)
        e = e * (1 - w) + lum * 0.8 * w
        save(np.dstack([e, m * 255]).astype(np.uint8), "orb_%s_empty" % k)
        layout["orbs"][k] = {"cx": cx, "cy": cy, "r": rg}

    # meniscus lines (generated): soft, bright in the middle
    for k, tint in (("h", (255, 120, 110)), ("m", (140, 210, 255))):
        w, h = 256, 9
        xx = np.linspace(-1, 1, w)[None, :]
        yy = np.linspace(-1, 1, h)[:, None]
        a = np.exp(-(yy / 0.35) ** 2) * np.clip(1 - xx ** 6, 0, 1)
        img = np.zeros((h, w, 4), np.float32)
        img[..., :3] = tint
        img[..., :3] += (255 - np.array(tint)) * np.exp(-(yy / 0.18) ** 2)[..., None] * 0.7
        img[..., 3] = a * 255
        save(np.clip(img, 0, 255).astype(np.uint8), "meniscus_%s" % k)

    # --- single slot pieces (before cleaning the bar) --------------------------
    def slot_x(i):
        return int(round(SLOT1_X + (i - 1) * SLOT_PITCH))

    s2 = slot_x(2)
    empty = L[SLOT_Y0:SLOT_Y1, s2:s2 + SLOT_W].copy()
    save(np.dstack([empty, np.full(empty.shape[:2], 255)]).astype(np.uint8), "slot_empty")
    normal = empty.copy()
    inset = 9
    inner = normal[inset:-inset, inset:-inset]
    normal[inset:-inset, inset:-inset] = ndimage.gaussian_filter(inner, (7, 7, 0))
    save(np.dstack([normal, np.full(normal.shape[:2], 255)]).astype(np.uint8), "slot_normal")
    # selected: slot 1's glow ring, hollow inside (drawn over the icon)
    g = 7
    sx = slot_x(1)
    sel = L[SLOT_Y0 - g:SLOT_Y1 + g, sx - g:sx + SLOT_W + g].copy()
    ref = L[SLOT_Y0 - g:SLOT_Y1 + g, s2 - g:s2 + SLOT_W + g]
    glow = np.clip((sel - ref).max(axis=2) / 90.0, 0, 1)  # what the glow adds over a normal slot
    hh, ww = glow.shape
    yy, xx = np.mgrid[0:hh, 0:ww]
    ring = np.minimum.reduce([xx, yy, ww - 1 - xx, hh - 1 - yy])
    glow[ring > g + 12] = 0  # the sword lives inside: keep only the border band
    warm = (sel[..., 0] - sel[..., 2]) > 60  # the glow is gold; the sword's steel is grey
    glow[~warm & (ring > g + 4)] = 0
    save(np.dstack([sel, glow * 255]).astype(np.uint8), "slot_selected")

    # flasks
    for k in ("h", "m"):
        x0, y0, x1, y1 = POTION[k]["flask"]
        f = L[y0:y1, x0:x1].copy()
        bgc = np.median(np.concatenate([f[:4].reshape(-1, 3), f[:, :4].reshape(-1, 3), f[:, -4:].reshape(-1, 3)]),
                        axis=0)
        diff = np.abs(f - bgc).max(axis=2)
        a = np.clip((diff - 10) / 30.0, 0, 1)
        lbl, n = ndimage.label(a > 0.5)
        if n:
            sizes = ndimage.sum(np.ones_like(a), lbl, range(1, n + 1))
            keep = lbl == (1 + int(np.argmax(sizes)))
            keep = ndimage.binary_fill_holes(ndimage.binary_dilation(keep, iterations=2))
            a = a * keep
            a = np.maximum(a, ndimage.binary_fill_holes(a > 0.5) * 1.0)
        a = ndimage.gaussian_filter(a, 0.7)
        save(np.dstack([f, a * 255]).astype(np.uint8), "potion_%s" % ("health" if k == "h" else "mana"))
        layout["potions"][k] = {"flask": [x0, y0, x1 - x0, y1 - y0], "plate": POTION[k]["plate"],
                                "slot": POTION[k]["slot"]}

    # xp fill: body stretched over the whole track, cap kept
    tx0, ty0, tx1, ty1 = XP_TRACK
    body = Image.fromarray(L[ty0:ty1, tx0:XP_FILL_END - XP_CAP_W].astype(np.uint8)).resize((tx1 - tx0, ty1 - ty0),
                                                                                           Image.BICUBIC)
    save(np.dstack([np.asarray(body), np.full((ty1 - ty0, tx1 - tx0), 255)]).astype(np.uint8), "xp_fill")
    cap = L[ty0:ty1, XP_FILL_END - XP_CAP_W:XP_FILL_END + 4]
    capa = np.clip((cap.max(axis=2) - 20) / 60.0, 0, 1)
    save(np.dstack([cap, capa * 255]).astype(np.uint8), "xp_cap")
    layout["xp"] = {"track": [tx0, ty0, tx1 - tx0, ty1 - ty0], "cap_w": XP_CAP_W + 4}

    # --- the bar, cleaned -------------------------------------------------------
    B = L.copy()
    # slot 1 <- slot 2 (frame, glow and sword gone), with its surroundings
    # (from slot 3: slot 2's surroundings still hold slot 1's glow on their left)
    s1 = slot_x(1)
    d = slot_x(3) - s1
    B[SLOT_Y0 - 9:DIGIT_Y1 + 6, s1 - 11:s1 + SLOT_W + 7] = L[SLOT_Y0 - 9:DIGIT_Y1 + 6, s1 - 11 + d:s1 + SLOT_W + 7 + d]
    # digits under the slots
    for i in range(1, 11):
        x = slot_x(i)
        cxd = x + SLOT_W // 2
        half = 26 if i == 10 else 18
        fill_rows_from_edges(B, cxd - half, DIGIT_Y0, cxd + half, DIGIT_Y1)
        layout["slots"].append([x, SLOT_Y0, SLOT_W, SLOT_Y1 - SLOT_Y0])
        layout["digits"].append([cxd, (DIGIT_Y0 + DIGIT_Y1) // 2])
    # potion flasks -> plain slot interior; plate text -> plate colour
    for k in ("h", "m"):
        x0, y0, x1, y1 = POTION[k]["flask"]
        src = L[SLOT_Y0 + 10:SLOT_Y1 - 10, s2 + 10:s2 + SLOT_W - 10]
        src = ndimage.gaussian_filter(src, (6, 6, 0))
        patch = np.asarray(Image.fromarray(src.astype(np.uint8)).resize((x1 - x0, y1 - y0), Image.BICUBIC))
        B[y0:y1, x0:x1] = patch
        px0, py0, px1, py1 = POTION[k]["plate"]
        region = B[py0:py1, px0:px1]
        mx = region.max(axis=2)
        txt = ndimage.binary_dilation(mx > 45, iterations=2)
        med = np.median(region[~txt], axis=0) if (~txt).any() else np.array([20, 20, 20])
        region[txt] = med
    # XP fill -> empty track (column profile from an empty part of the track)
    col = L[ty0 - 3:ty1 + 3, 1300:1301]
    B[ty0 - 3:ty1 + 3, tx0:XP_FILL_END + 8] = np.repeat(col, XP_FILL_END + 8 - tx0, axis=1)

    bx0, by0, bx1, by1 = BAR_BOX
    bar = key_background(B[by0:by1, bx0:bx1].copy())
    save(bar, "bar")
    piece("bar", BAR_BOX)

    charge_bars(L, B, layout)
    bow_arc(layout)
    atlas(layout)

    # --- layout file for the game ---------------------------------------------
    os.makedirs(os.path.dirname(LAYOUT_LUA), exist_ok=True)
    with open(LAYOUT_LUA, "w", encoding="utf-8", newline="\n") as fh:
        fh.write("-- SPDX-License-Identifier: GPL-3.0-or-later\n")
        fh.write("-- GENERATED by tools/hud/slice.py; do not edit. Rectangles are {x, y, w, h}\n")
        fh.write("-- in the art's canvas pixels (docs/design/hud/hud-full-layout.png).\n")
        fh.write("return " + to_lua(layout) + "\n")

    preview(layout)
    print("slices ->", OUT)


def charge_bars(L, B, layout):
    """Spell cast bar (hud.md): the XP bar's empty track with its right end
    ornament, mirrored on the left, plus fills recoloured from the XP fill:
    blue while casting, bright cyan at READY."""
    tx0, ty0, tx1, ty1 = XP_TRACK
    ex1 = 1828                                    # right end ornament of the XP bar
    y0, y1 = ty0 - 14, ty1 + 14
    mid = B[y0:y1, 1100:1500]                     # plain track (no centre ornament)
    right = B[y0:y1, tx1 - 10:ex1]
    left = right[:, ::-1]
    frame = np.concatenate([left, mid, right], axis=1)
    rgba = key_background(frame.copy())
    save(rgba, "castbar_frame")
    lw = left.shape[1]
    layout["castbar"] = {"track": [lw - 2, 14, mid.shape[1] + 4, ty1 - ty0], "size": [rgba.shape[1], rgba.shape[0]]}
    xp = np.asarray(Image.open(os.path.join(OUT, "xp_fill.png"))).astype(np.float32)
    rgb = xp[..., :3]
    blue = np.stack([rgb[..., 2] * 0.6, rgb[..., 1] * 0.75, np.minimum(255, rgb[..., 0] * 1.15)], axis=2)
    save(np.dstack([blue, xp[..., 3]]).astype(np.uint8), "castbar_fill")
    lum = rgb.mean(axis=2, keepdims=True)
    ready = np.clip(np.concatenate([lum * 0.75, lum * 1.05, lum * 1.3], axis=2) + 30, 0, 255)
    save(np.dstack([ready, xp[..., 3]]).astype(np.uint8), "castbar_ready")


def bow_arc(layout, frames=21, size=168):
    """Bow draw ring around the crosshair (hud.md): a 270 degree amber arc
    opening at the bottom, pre-rendered at 0..100 % in 5 % steps (SE's
    ImGui has no draw list, so no radial wipe at runtime). Marker at the
    30 % minimum shot, tick at full draw."""
    ss = 3
    S = size * ss
    c = S / 2
    r0, r1 = S * 0.36, S * 0.42
    yy, xx = np.mgrid[0:S, 0:S].astype(np.float32)
    d = np.sqrt((xx - c) ** 2 + (yy - c) ** 2)
    # angle measured clockwise from the bottom-left start of the arc
    ang = (np.degrees(np.arctan2(xx - c, -(yy - c))) + 360) % 360   # 0 = up, clockwise
    start = 225.0                                                    # bottom-left
    along = (ang - start) % 360                                      # 0..360 from the start
    sweep = 270.0
    ring = np.clip(np.minimum(d - r0, r1 - d) / (1.2 * ss), 0, 1)
    on_arc = along <= sweep

    def tick_mask(frac, half_deg, out):
        a = (start + frac * sweep) % 360
        da = np.abs(((ang - a) + 180) % 360 - 180)
        return (da < half_deg) & (d > r0 - out * ss) & (d < r1 + out * ss)

    names = []
    for i in range(frames):
        f = i / (frames - 1)
        img = np.zeros((S, S, 4), np.float32)
        track = ring * on_arc
        img[..., :3] = np.array([40, 30, 18])
        img[..., 3] = track * 150
        filled = track * (along <= f * sweep)
        full = f >= 0.999
        col = np.array([255, 214, 120]) if full else np.array([255, 170, 60])
        img[..., :3] = np.where(filled[..., None] > 0, col, img[..., :3])
        img[..., 3] = np.maximum(img[..., 3], filled * 255)
        if full:
            glow = np.clip(1 - np.abs(d - (r0 + r1) / 2) / (9 * ss), 0, 1) * on_arc
            img[..., :3] = np.where((glow > 0)[..., None] & (filled[..., None] == 0), col, img[..., :3])
            img[..., 3] = np.maximum(img[..., 3], glow * 120)
        for frac, half, out, colr in ((0.30, 1.2, 4, (255, 255, 255)), (1.0, 1.6, 6, (255, 230, 150))):
            m = tick_mask(frac, half, out)
            img[..., :3] = np.where(m[..., None], np.array(colr), img[..., :3])
            img[..., 3] = np.where(m, 235, img[..., 3])
        im = Image.fromarray(np.clip(img, 0, 255).astype(np.uint8)).resize((size, size), Image.LANCZOS)
        n = "bow_%02d" % i
        im.save(os.path.join(OUT, n + ".png"))
        names.append(n)
    layout["bow"] = {"frames": frames, "size": size}


ATLAS_UUID = "5b0b4f6e-2d6a-4c1e-9b7a-d4a0f5e1c001"
ICON_PREFIX = "DAG_HUD_"
# Same layout as Mod Configuration Menu's shipped UI textures (the one that
# is known to load): Public/Shared/{Assets/Textures/Icons, Content/UI/[PAK]_x,
# GUI}, unique DAG_ names. 2026-10-12 playtest: a bank only as merged.lsx
# under Public/DarkAndGate was never loaded ("NOT FOUND in the texture bank").
SHARED = os.path.join(ROOT, "mod", "DarkAndGate", "Public", "Shared")
ATLAS_DDS = os.path.join(SHARED, "Assets", "Textures", "Icons", "DAG_HUD_Atlas.dds")
ATLAS_BANK = os.path.join(SHARED, "Content", "UI", "[PAK]_DAG_HUD", "merged.lsx")
ATLAS_GUI = os.path.join(SHARED, "GUI", "DAG_HUD_Atlas.lsx")
DIVINE = os.path.join(ROOT, "tools", "lslib", "Packed", "Tools", "Divine.exe")


def atlas(layout, W=2048):
    """Pack every layer into one RGBA texture (shelf packing), write it as an
    uncompressed DX10 DDS (R8G8B8A8, the format MCM ships), a texture bank
    entry (.lsx + .lsf) and an icon atlas naming each layer DAG_HUD_<layer>,
    and record each layer's UV rect (ImGui draws them by icon name and
    clips them by UV)."""
    names = sorted(f[:-4] for f in os.listdir(OUT) if f.endswith(".png") and f not in ("preview.png", "atlas.png"))
    imgs = {n: Image.open(os.path.join(OUT, n + ".png")).convert("RGBA") for n in names}
    order = sorted(names, key=lambda n: -imgs[n].height)
    x = y = rowh = 0
    pos = {}
    pad = 2
    for n in order:
        im = imgs[n]
        if x + im.width + pad > W:
            x, y, rowh = 0, y + rowh + pad, 0
        pos[n] = (x, y)
        x += im.width + pad
        rowh = max(rowh, im.height)
    H = 1
    while H < y + rowh:
        H *= 2
    sheet = Image.new("RGBA", (W, H), (0, 0, 0, 0))
    uv = {}
    for n in names:
        px, py = pos[n]
        im = imgs[n]
        sheet.paste(im, (px, py))
        uv[n] = [px / W, py / H, (px + im.width) / W, (py + im.height) / H, im.width, im.height]
    sheet.save(os.path.join(OUT, "atlas.png"))
    write_dds(sheet, ATLAS_DDS)
    os.makedirs(os.path.dirname(ATLAS_BANK), exist_ok=True)
    with open(ATLAS_BANK, "w", encoding="utf-8", newline=chr(10)) as fh:
        fh.write(BANK_LSX.format(uuid=ATLAS_UUID, src="Public/Shared/Assets/Textures/Icons/DAG_HUD_Atlas.dds"))
    lsf = ATLAS_BANK[:-4] + ".lsf"
    if os.path.exists(DIVINE):
        import subprocess
        r = subprocess.run([DIVINE, "--game", "bg3", "--action", "convert-resource", "--source", ATLAS_BANK,
                            "--destination", lsf, "--loglevel", "warn"], capture_output=True, text=True)
        print("texture bank .lsf:", "ok" if r.returncode == 0 and os.path.exists(lsf) else ("FAILED " + r.stdout + r.stderr))
    else:
        print("WARNING: Divine.exe not found, no merged.lsf written")
    os.makedirs(os.path.dirname(ATLAS_GUI), exist_ok=True)
    icons = "".join(ICON_UV.format(key=ICON_PREFIX + n, u1=uv[n][0], v1=uv[n][1], u2=uv[n][2], v2=uv[n][3]) for n in names)
    with open(ATLAS_GUI, "w", encoding="utf-8", newline=chr(10)) as fh:
        fh.write(GUI_LSX.format(uuid=ATLAS_UUID, w=W, h=H, icons=icons))
    layout["atlas"] = {"uuid": ATLAS_UUID, "prefix": ICON_PREFIX, "size": [W, H], "uv": uv}
    print("atlas %dx%d, %d layers -> %s" % (W, H, len(names), ATLAS_DDS))


GUI_LSX = r"""<?xml version="1.0" encoding="UTF-8"?>
<save>
  <version major="4" minor="0" revision="9" build="322"/>
  <region id="TextureAtlasInfo">
    <node id="root">
      <children>
        <node id="TextureAtlasIconSize">
          <attribute id="Height" value="64" type="int32"/>
          <attribute id="Width" value="64" type="int32"/>
        </node>
        <node id="TextureAtlasPath">
          <attribute id="Path" value="Assets\Textures\Icons\DAG_HUD_Atlas.dds" type="string"/>
          <attribute id="UUID" value="{uuid}" type="FixedString"/>
        </node>
        <node id="TextureAtlasTextureSize">
          <attribute id="Height" value="{h}" type="int32"/>
          <attribute id="Width" value="{w}" type="int32"/>
        </node>
      </children>
    </node>
  </region>
  <region id="IconUVList">
    <node id="root">
      <children>
{icons}      </children>
    </node>
  </region>
</save>
"""

ICON_UV = """        <node id="IconUV">
          <attribute id="MapKey" value="{key}" type="FixedString"/>
          <attribute id="U1" value="{u1:.6f}" type="float"/>
          <attribute id="V1" value="{v1:.6f}" type="float"/>
          <attribute id="U2" value="{u2:.6f}" type="float"/>
          <attribute id="V2" value="{v2:.6f}" type="float"/>
        </node>
"""


BANK_LSX = """<?xml version="1.0" encoding="utf-8"?>
<save>
	<version major="4" minor="4" revision="4" build="602" />
	<region id="TextureBank">
		<node id="TextureBank">
			<children>
				<node id="Resource">
					<attribute id="ID" type="FixedString" value="{uuid}" />
					<attribute id="Localized" type="bool" value="False" />
					<attribute id="Name" type="LSString" value="DAG_HUD_Atlas" />
					<attribute id="SRGB" type="bool" value="False" />
					<attribute id="SourceFile" type="LSString" value="{src}" />
					<attribute id="Streaming" type="bool" value="True" />
					<attribute id="Template" type="FixedString" value="Icons_Items" />
					<attribute id="Type" type="int32" value="0" />
					<attribute id="_OriginalFileVersion_" type="int64" value="144115188075855873" />
				</node>
			</children>
		</node>
	</region>
</save>
"""


def write_dds(img, path):
    """Uncompressed DX10 DDS, DXGI_FORMAT_R8G8B8A8_UNORM_SRGB (29), 1 mip --
    header fields mirror Mod Configuration Menu's shipped UI textures."""
    import struct
    w, h = img.size
    hdr = struct.pack("<4s31I", b"DDS ", 124, 0x2100F, h, w, w * 4, 1, 1, *([0] * 11),
                      32, 4, struct.unpack("<I", b"DX10")[0], 0, 0, 0, 0, 0, 0x1000, 0, 0, 0, 0)
    dx10 = struct.pack("<5I", 29, 3, 0, 1, 0)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as fh:
        fh.write(hdr + dx10 + img.tobytes())


def to_lua(v, ind=0):
    pad = "    " * (ind + 1)
    if isinstance(v, dict):
        items = ["%s%s = %s" % (pad, k if k.isidentifier() else "[%s]" % json.dumps(k), to_lua(v[k], ind + 1))
                 for k in sorted(v)]
        return "{\n" + ",\n".join(items) + ",\n" + "    " * ind + "}"
    if isinstance(v, (list, tuple)):
        if all(isinstance(x, (int, float)) for x in v):
            return "{ " + ", ".join(str(int(x)) if float(x).is_integer() else "%.6f" % x for x in v) + " }"
        return "{\n" + ",\n".join(pad + to_lua(x, ind + 1) for x in v) + ",\n" + "    " * ind + "}"
    if isinstance(v, (int, np.integer)):
        return str(int(v))
    if isinstance(v, float):
        return "%.3f" % v
    return json.dumps(v)


def preview(layout):
    """preview.png: every slice on a checkerboard, plus the recomposed HUD at
    100 / 50 / 15 % over a mid-grey "game" backdrop."""
    names = ["orb_h_frame", "orb_h_full", "orb_h_empty", "orb_m_frame", "orb_m_full", "orb_m_empty",
             "slot_normal", "slot_empty", "slot_selected", "potion_health", "potion_mana", "xp_cap",
             "meniscus_h", "meniscus_m"]
    imgs = {n: Image.open(os.path.join(OUT, n + ".png")) for n in names + ["bar", "xp_fill"]}
    W = 2200
    sheet = Image.new("RGBA", (W, 2050), (40, 40, 40, 255))
    # checkerboard
    ck = Image.new("RGBA", (W, 720), (0, 0, 0, 0))
    dc = ImageDraw.Draw(ck)
    for y in range(0, 720, 16):
        for x in range(0, W, 16):
            dc.rectangle([x, y, x + 15, y + 15], fill=(90, 90, 90, 255) if (x // 16 + y // 16) % 2 else (60, 60, 60, 255))
    sheet.paste(ck, (0, 0))
    x, y, rowh = 10, 10, 0
    d = ImageDraw.Draw(sheet)
    for n in names:
        im = imgs[n]
        if x + im.width > W:
            x, y, rowh = 10, y + rowh + 30, 0
        sheet.alpha_composite(im, (x, y))
        d.text((x, y + im.height + 2), n, fill=(255, 255, 0, 255))
        x += im.width + 20
        rowh = max(rowh, im.height)
    by = 470
    sheet.alpha_composite(imgs["bar"], (10, by))
    d.text((10, by + imgs["bar"].height + 2), "bar (cleaned)", fill=(255, 255, 0, 255))

    # recomposed at three fill levels
    y0 = 760
    for frac in (1.0, 0.5, 0.15):
        bg = Image.new("RGBA", (LAYOUT_W, 420), (70, 78, 70, 255))
        compose(bg, layout, imgs, frac, -270)
        sheet.alpha_composite(bg.resize((W - 20, int(420 * (W - 20) / LAYOUT_W))), (10, y0))
        d.text((14, y0 + 4), "recomposed, HP / mana / XP at %d %%" % int(frac * 100), fill=(255, 255, 0, 255))
        y0 += 430
    sheet.convert("RGB").save(os.path.join(OUT, "preview.png"))


def compose(canvas, layout, imgs, frac, dy):
    P = layout["pieces"]

    def put(name, img=None):
        x, y, w, h = P[name]
        canvas.alpha_composite(img or imgs[name], (x, y + dy))

    for k in ("h", "m"):
        o = layout["orbs"][k]
        put("orb_%s_empty" % k)
        full = imgs["orb_%s_full" % k]
        x, y, w, h = P["orb_%s_full" % k]
        cut = int(round(h * (1 - frac)))
        if cut < h:
            part = full.crop((0, cut, w, h))
            canvas.alpha_composite(part, (x, y + cut + dy))
            # meniscus: chord width at that height
            ly = cut - h / 2
            chord = 2 * np.sqrt(max(o["r"] ** 2 - ly ** 2, 0))
            if 0 < frac < 1 and chord > 8:
                m = imgs["meniscus_%s" % k].resize((int(chord), 9))
                canvas.alpha_composite(m, (int(o["cx"] - chord / 2), int(y + cut - 4 + dy)))
        put("orb_%s_frame" % k)
    put("bar")
    tx, ty, tw, th = layout["xp"]["track"]
    fw = int(tw * frac)
    if fw > 0:
        canvas.alpha_composite(imgs["xp_fill"].crop((0, 0, fw, th)), (tx, ty + dy))
        cap = imgs["xp_cap"]
        canvas.alpha_composite(cap, (tx + fw - cap.width, ty + dy))
    # a selected slot 1 and some "icons"
    sx, sy, sw, sh = layout["slots"][0]
    sel = imgs["slot_selected"]
    canvas.alpha_composite(sel, (sx - 7, sy - 7 + dy))
    for k, n in (("h", "potion_health"), ("m", "potion_mana")):
        fx, fy, fw2, fh2 = layout["potions"][k]["flask"]
        canvas.alpha_composite(imgs[n], (fx, fy + dy))


if __name__ == "__main__":
    sys.exit(main())
