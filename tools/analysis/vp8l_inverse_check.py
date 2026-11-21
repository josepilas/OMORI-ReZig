#!/usr/bin/env python3
"""Python reference inverse-transforms for VP8L — applies them to the
dumped pre-inverse ARGB and compares with Pillow. Isolates the stage
where the Zig decoder diverges (LZ77 vs transforms).
"""
import struct
import sys
from PIL import Image

W, H = 1464, 1053

# transforms in stream order (from the Zig trace): subtract_green,
# predictor (bits=5), cross_color (bits=5). Inverse in REVERSE order:
# cross_color → predictor → subtract_green.
PRED_BITS = 5
XC_BITS = 5


def sub_size(size, bits):
    return (size + (1 << bits) - 1) >> bits


def clip255(a):
    return 0 if a < 0 else 255 if a > 255 else a


def avg2(a, b):
    return (((a ^ b) & 0xFEFEFEFE) >> 1) + (a & b)


def avg3(a, b, c):
    return avg2(avg2(a, c), b)


def avg4(a, b, c, d):
    return avg2(avg2(a, b), avg2(c, d))


def add_pixels(a, b):
    aa = (((a >> 24) & 0xFF) + ((b >> 24) & 0xFF)) & 0xFF
    r = (((a >> 16) & 0xFF) + ((b >> 16) & 0xFF)) & 0xFF
    g = (((a >> 8) & 0xFF) + ((b >> 8) & 0xFF)) & 0xFF
    bl = ((a & 0xFF) + (b & 0xFF)) & 0xFF
    return (aa << 24) | (r << 16) | (g << 8) | bl


def sub3(a, b, c):
    return abs(b - c) - abs(a - c)


def select_pred(a, b, c):
    pa_pb = (sub3((a >> 24) & 0xFF, (b >> 24) & 0xFF, (c >> 24) & 0xFF)
             + sub3((a >> 16) & 0xFF, (b >> 16) & 0xFF, (c >> 16) & 0xFF)
             + sub3((a >> 8) & 0xFF, (b >> 8) & 0xFF, (c >> 8) & 0xFF)
             + sub3(a & 0xFF, b & 0xFF, c & 0xFF))
    return a if pa_pb <= 0 else b


def cas_full(c0, c1, c2):
    out = 0
    for shift in (24, 16, 8, 0):
        a = (c0 >> shift) & 0xFF
        b = (c1 >> shift) & 0xFF
        c = (c2 >> shift) & 0xFF
        out |= clip255(a + b - c) << shift
    return out


def cas_half(c0, c1, c2):
    ave = avg2(c0, c1)
    out = 0
    for shift in (24, 16, 8, 0):
        a = (ave >> shift) & 0xFF
        b = (c2 >> shift) & 0xFF
        # C integer division truncates toward zero
        d = a - b
        out |= clip255(a + int(d / 2)) << shift
    return out


def predict(mode, left, top, topright, topleft):
    if mode == 0:
        return 0xFF000000
    if mode == 1:
        return left
    if mode == 2:
        return top
    if mode == 3:
        return topright
    if mode == 4:
        return topleft
    if mode == 5:
        return avg3(left, top, topright)
    if mode == 6:
        return avg2(left, topleft)
    if mode == 7:
        return avg2(left, top)
    if mode == 8:
        return avg2(topleft, top)
    if mode == 9:
        return avg2(top, topright)
    if mode == 10:
        return avg4(left, topleft, top, topright)
    if mode == 11:
        return select_pred(top, left, topleft)
    if mode == 12:
        return cas_full(left, top, topleft)
    if mode == 13:
        return cas_half(left, top, topleft)
    return 0xFF000000


def i8(v):
    return v - 256 if v >= 128 else v


def color_delta(pred, color):
    return (pred * color) >> 5  # both i8 → int


def main():
    raw = open(sys.argv[1] if len(sys.argv) > 1 else "/tmp/raw_argb.bin", "rb").read()
    px = list(struct.unpack(f"<{len(raw)//4}I", raw))
    assert len(px) == W * H, f"{len(px)} != {W*H}"

    # --- cross-color inverse (tiles from the same raw dump? NO — the tile
    # data came from the Zig decode; re-deriving here needs the tiles.
    # Instead: we cheat the check — compare the RAW dump's transformed
    # output only for subtract_green, which needs no tile data.
    # For the tile transforms, we reuse the tile pixel dump.
    tiles_pred = None
    tiles_xc = None
    try:
        tp = open("/tmp/tiles_pred.bin", "rb").read()
        tiles_pred = list(struct.unpack(f"<{len(tp)//4}I", tp))
        tx = open("/tmp/tiles_xc.bin", "rb").read()
        tiles_xc = list(struct.unpack(f"<{len(tx)//4}I", tx))
    except FileNotFoundError:
        pass

    if tiles_pred is None:
        print("tile dumps missing — only LZ77-stage compare possible")
        return

    # cross_color inverse
    tiles_per_row = sub_size(W, XC_BITS)
    for y in range(H):
        for x in range(W):
            idx = y * W + x
            tidx = (y >> XC_BITS) * tiles_per_row + (x >> XC_BITS)
            code = tiles_xc[tidx]
            g2r = i8(code & 0xFF)
            g2b = i8((code >> 8) & 0xFF)
            r2b = i8((code >> 16) & 0xFF)
            p = px[idx]
            green = i8((p >> 8) & 0xFF)
            red = (p >> 16) & 0xFF
            blue = p & 0xFF
            new_red = (red + color_delta(g2r, green)) & 0xFF
            new_blue = (blue + color_delta(g2b, green) + color_delta(r2b, i8(new_red))) & 0xFF
            px[idx] = (p & 0xFF00FF00) | (new_red << 16) | new_blue

    # predictor inverse
    tiles_per_row_p = sub_size(W, PRED_BITS)
    for y in range(H):
        for x in range(W):
            idx = y * W + x
            if y == 0:
                pred = 0xFF000000 if x == 0 else px[idx - 1]
            elif x == 0:
                pred = px[idx - W]
            else:
                tidx = (y >> PRED_BITS) * tiles_per_row_p + (x >> PRED_BITS)
                mode = (tiles_pred[tidx] >> 8) & 0xF
                pred = predict(mode, px[idx - 1], px[idx - W], px[idx - W + 1], px[idx - W - 1])
            px[idx] = add_pixels(px[idx], pred)

    # subtract_green inverse
    for i in range(len(px)):
        p = px[i]
        g = (p >> 8) & 0xFF
        rb = (p & 0x00FF00FF) + (g << 16) | 0 if False else (p & 0x00FF00FF)
        rb = ((p & 0x00FF00FF) + ((g << 16) | g)) & 0x00FF00FF
        px[i] = (p & 0xFF00FF00) | rb

    out = b"".join(struct.pack("<I", p) for p in px)
    # ARGB → RGBA
    rgba = bytearray()
    for p in px:
        rgba += bytes(((p >> 16) & 0xFF, (p >> 8) & 0xFF, p & 0xFF, (p >> 24) & 0xFF))

    ref = Image.open(sys.argv[2] if len(sys.argv) > 2 else
                     "/home/z/my-project/cache/apk_part/assets/www/img/atlases/Omori_TitleScreen.png").convert("RGBA")
    refb = ref.tobytes()
    if bytes(rgba) == refb:
        print("PY-INVERSE MATCH: LZ77 output + python inverse = reference — the Zig inverse has the bug")
        return
    diff = sum(1 for a, b in zip(rgba, refb) if a != b)
    print(f"PY-INVERSE MISMATCH: {diff}/{len(refb)} bytes differ — the LZ77 stage itself diverges")
    for i, (a, b) in enumerate(zip(rgba, refb)):
        if a != b:
            print(f"  first diff byte {i} (pixel {i//4} ch {i%4}): py={a} ref={b}")
            break


if __name__ == "__main__":
    main()
