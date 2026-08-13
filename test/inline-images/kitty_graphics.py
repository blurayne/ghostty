#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""
Manual demo of the Kitty graphics protocol (Ghostty's native inline images).

Spec: https://sw.kovidgoyal.net/kitty/graphics-protocol/

Wire framing (APC):
    ESC _ G <control keys, comma separated> ; <base64 payload chunk> ESC \

The payload is chunked into <=4096 base64-byte pieces. Only the first chunk
carries the control keys; every chunk carries m=1 (more coming) except the
last, which carries m=0.

Key control keys used here:
    a=T   action: transmit AND display
    f=100 payload is a PNG file (Ghostty also supports f=32 raw RGBA)
    q=2   quiet: suppress the terminal's OK/error acknowledgement
    c=,r= display size in terminal columns/rows (optional)
    C=1   do not move the cursor after placing the image

Run this INSIDE Ghostty (or any Kitty-graphics-capable terminal).

Usage:
    test/inline-images/kitty_graphics.py            # run the whole tour
    test/inline-images/kitty_graphics.py basic
    test/inline-images/kitty_graphics.py sized
    test/inline-images/kitty_graphics.py nocursor
    test/inline-images/kitty_graphics.py rgba       # raw RGBA (f=32) instead of PNG
"""

import base64
import io
import sys

from PIL import Image, ImageDraw


def make_image(label: str, w: int = 240, h: int = 120) -> Image.Image:
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (int(255 * y / h), int(255 * x / w), 200)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255))
    d.text((8, 8), label, fill=(255, 255, 255))
    return img


def w(data: bytes) -> None:
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def caption(text: str) -> None:
    print(f"\n\x1b[1m{text}\x1b[0m")
    sys.stdout.flush()


def emit(payload: bytes, controls: str, chunk: int = 4096) -> None:
    """Transmit `payload` (already base64) as one APC _G command, chunked."""
    total = len(payload)
    i = 0
    first = True
    while i < total or first:
        piece = payload[i : i + chunk]
        i += chunk
        more = 1 if i < total else 0
        if first:
            ctl = f"{controls},m={more}"
            first = False
        else:
            ctl = f"m={more}"
        w(b"\x1b_G" + ctl.encode("ascii") + b";" + piece + b"\x1b\\")
        if more == 0:
            break


def emit_png(img: Image.Image, extra: str = "") -> None:
    buf = io.BytesIO()
    img.save(buf, "PNG")
    b64 = base64.b64encode(buf.getvalue())
    controls = "a=T,f=100,q=2"
    if extra:
        controls += "," + extra
    emit(b64, controls)


def demo_basic() -> None:
    caption("basic — a=T,f=100 (PNG), auto size")
    emit_png(make_image("kitty basic"))
    print()


def demo_sized() -> None:
    caption("sized — c=20,r=6 (display footprint in terminal cells)")
    emit_png(make_image("20x6 cells"), extra="c=20,r=6")
    print()


def demo_nocursor() -> None:
    caption("nocursor — C=1 (cursor stays put; text prints over/after the image)")
    emit_png(make_image("no cursor move", w=120, h=48), extra="c=10,r=2,C=1")
    w(b"  <-- text follows on the same row\n")


def demo_rgba() -> None:
    caption("rgba — f=32 raw RGBA (s=width, v=height), no PNG encoder needed")
    img = make_image("raw RGBA", w=160, h=80).convert("RGBA")
    b64 = base64.b64encode(img.tobytes())
    emit(b64, f"a=T,f=32,q=2,s={img.width},v={img.height}")
    print()


DEMOS = {
    "basic": demo_basic,
    "sized": demo_sized,
    "nocursor": demo_nocursor,
    "rgba": demo_rgba,
}


def main() -> int:
    args = sys.argv[1:]
    if not args or args == ["tour"]:
        for fn in DEMOS.values():
            fn()
        return 0
    rc = 0
    for name in args:
        fn = DEMOS.get(name)
        if fn is None:
            print(f"unknown demo: {name}", file=sys.stderr)
            print(f"choices: {', '.join(DEMOS)} (or no args for the full tour)", file=sys.stderr)
            rc = 2
            continue
        fn()
    return rc


if __name__ == "__main__":
    raise SystemExit(main())
