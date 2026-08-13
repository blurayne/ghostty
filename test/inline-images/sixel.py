#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""
Manual demo of Sixel graphics (DCS-based inline images).

Spec: https://www.vt100.net/docs/vt3xx-gp/chapter14.html  (and the de-facto
DEC/libsixel conventions every modern terminal follows).

Wire framing (DCS):
    ESC P <p1>;<p2>;<p3> q  <sixel data>  ESC \

The image is quantised to <=256 palette colours. Each colour register is
declared with  #<n>;2;<r>;<g>;<b>  (RGB components in 0..100). The bitmap is
emitted in horizontal bands 6 pixels tall: each byte encodes a vertical column
of 6 pixels as (0x3F + bitmask). '$' returns to the band start to overprint the
next colour; '-' advances to the next band. Runs are compressed with '!<n>'.

Run this INSIDE Ghostty (or any Sixel-capable terminal).

Usage:
    test/inline-images/sixel.py            # run the whole tour
    test/inline-images/sixel.py gradient
    test/inline-images/sixel.py bands
    test/inline-images/sixel.py file PATH  # encode an arbitrary image file
"""

import sys

from PIL import Image, ImageDraw


def w(data: bytes) -> None:
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def caption(text: str) -> None:
    print(f"\n\x1b[1m{text}\x1b[0m")
    sys.stdout.flush()


def to_sixel(img: Image.Image, max_colors: int = 255) -> bytes:
    """Encode a PIL image to a Sixel DCS string."""
    img = img.convert("RGB")
    pal = img.convert("P", palette=Image.ADAPTIVE, colors=max_colors)
    palette = pal.getpalette()  # flat [r,g,b, r,g,b, ...]
    width, height = pal.size
    px = pal.load()

    out = bytearray(b"\x1bP0;1;0q")            # DCS ... q  (P2=1: unset pixels transparent)
    out += f'"1;1;{width};{height}'.encode()  # raster attributes: pan;pad;width;height

    # Declare only the colour registers that actually appear.
    used = sorted({px[x, y] for y in range(height) for x in range(width)})
    for idx in used:
        r = round(palette[idx * 3] * 100 / 255)
        g = round(palette[idx * 3 + 1] * 100 / 255)
        b = round(palette[idx * 3 + 2] * 100 / 255)
        out += f"#{idx};2;{r};{g};{b}".encode()

    for top in range(0, height, 6):
        band_rows = range(top, min(top + 6, height))
        band_colors = sorted({px[x, y] for y in band_rows for x in range(width)})
        for ci, idx in enumerate(band_colors):
            if ci:
                out += b"$"  # carriage return within the band (overprint)
            out += f"#{idx}".encode()
            # Build this colour's sixel row with run-length compression.
            prev = -1
            count = 0
            for x in range(width):
                bits = 0
                for bit in range(6):
                    y = top + bit
                    if y < height and px[x, y] == idx:
                        bits |= 1 << bit
                ch = 0x3F + bits
                if ch == prev:
                    count += 1
                else:
                    _flush(out, prev, count)
                    prev, count = ch, 1
            _flush(out, prev, count)
        out += b"-"  # next band
    out += b"\x1b\\"
    return bytes(out)


def _flush(out: bytearray, ch: int, count: int) -> None:
    if ch < 0 or count == 0:
        return
    if count >= 4:
        out += b"!" + str(count).encode() + bytes([ch])
    else:
        out += bytes([ch]) * count


def make_gradient(w_: int = 160, h_: int = 90) -> Image.Image:
    img = Image.new("RGB", (w_, h_))
    px = img.load()
    for y in range(h_):
        for x in range(w_):
            px[x, y] = (int(255 * x / w_), int(255 * y / h_), 128)
    d = ImageDraw.Draw(img)
    d.text((6, 6), "sixel gradient", fill=(255, 255, 255))
    return img


def make_bands(w_: int = 160, h_: int = 60) -> Image.Image:
    colors = [
        (220, 40, 40),
        (220, 140, 40),
        (220, 220, 40),
        (40, 200, 40),
        (40, 120, 220),
        (150, 60, 200),
    ]
    img = Image.new("RGB", (w_, h_))
    d = ImageDraw.Draw(img)
    bw = w_ / len(colors)
    for i, c in enumerate(colors):
        d.rectangle([int(i * bw), 0, int((i + 1) * bw), h_], fill=c)
    return img


def demo_gradient() -> None:
    caption("gradient — 256-colour adaptive palette")
    w(to_sixel(make_gradient()))
    print()


def demo_bands() -> None:
    caption("bands — six solid colour bands (RLE compresses each row)")
    w(to_sixel(make_bands()))
    print()


def demo_file(path: str) -> None:
    caption(f"file — {path}")
    img = Image.open(path)
    img.thumbnail((320, 240))  # keep the demo output small
    w(to_sixel(img))
    print()


def main() -> int:
    args = sys.argv[1:]
    if not args or args == ["tour"]:
        demo_gradient()
        demo_bands()
        return 0
    if args[0] == "file":
        if len(args) < 2:
            print("usage: sixel.py file PATH", file=sys.stderr)
            return 2
        demo_file(args[1])
        return 0
    rc = 0
    for name in args:
        if name == "gradient":
            demo_gradient()
        elif name == "bands":
            demo_bands()
        else:
            print(f"unknown demo: {name}", file=sys.stderr)
            print("choices: gradient, bands, file PATH (or no args for the tour)", file=sys.stderr)
            rc = 2
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
