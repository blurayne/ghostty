#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = ["pillow>=10"]
# ///
"""
Manual demo of the iTerm2 Inline Image Protocol (OSC 1337 File=).

Spec: https://iterm2.com/documentation-images.html

Wire framing (single-shot):
    ESC ] 1337 ; File = <k>=<v> ; <k>=<v> ... : <base64 image bytes> BEL

Multipart (spans several OSC sequences):
    ESC ] 1337 ; MultipartFile = <k>=<v> ; ...          BEL   (header, no data)
    ESC ] 1337 ; FilePart = <base64 chunk>              BEL   (repeat)
    ESC ] 1337 ; FileEnd                                BEL   (finalise)

Ghostty specifics (this fork):
  * Only PNG payloads are displayed (the wuffs decoder is PNG-only); other
    formats are detected by magic bytes and skipped with a warning.
  * A single-shot File= with inline=0 / dispositionType=attachment is IGNORED.
    Downloads happen only through the MultipartFile= path with inline=0.
  * Dimensions accept  N (cells) | Npx (pixels) | N% (viewport percent) | auto.

Run this INSIDE Ghostty. In a terminal without OSC 1337 support the sequences
are silently ignored.

Usage:
    test/inline-images/iterm2_osc1337.py            # run the whole tour
    test/inline-images/iterm2_osc1337.py basic
    test/inline-images/iterm2_osc1337.py cells
    test/inline-images/iterm2_osc1337.py pixels
    test/inline-images/iterm2_osc1337.py percent
    test/inline-images/iterm2_osc1337.py aspect
    test/inline-images/iterm2_osc1337.py nocursor
    test/inline-images/iterm2_osc1337.py multipart
    test/inline-images/iterm2_osc1337.py download
"""

import base64
import io
import sys

from PIL import Image, ImageDraw


def make_png(label: str, w: int = 240, h: int = 120) -> bytes:
    """A labelled diagonal-gradient PNG so each demo is visually distinct."""
    img = Image.new("RGB", (w, h))
    px = img.load()
    for y in range(h):
        for x in range(w):
            px[x, y] = (int(255 * x / w), int(255 * y / h), 160)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, w - 1, h - 1], outline=(255, 255, 255))
    d.text((8, 8), label, fill=(255, 255, 255))
    buf = io.BytesIO()
    img.save(buf, "PNG")
    return buf.getvalue()


def w(data: bytes) -> None:
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def caption(text: str) -> None:
    print(f"\n\x1b[1m{text}\x1b[0m")
    sys.stdout.flush()


def emit_file(args: list[tuple[str, str]], data: bytes) -> None:
    """Single-shot: ESC ] 1337 ; File=<args> : <b64> BEL"""
    kv = ";".join(f"{k}={v}" for k, v in args)
    w(b"\x1b]1337;File=" + kv.encode("ascii") + b":" + base64.b64encode(data) + b"\x07")


def emit_multipart(header: list[tuple[str, str]], data: bytes, chunk: int = 1024) -> None:
    """Multipart: MultipartFile header, then FilePart chunks, then FileEnd."""
    b64 = base64.b64encode(data)
    hdr = ";".join(f"{k}={v}" for k, v in header)
    w(b"\x1b]1337;MultipartFile=" + hdr.encode("ascii") + b"\x07")
    for i in range(0, len(b64), chunk):
        w(b"\x1b]1337;FilePart=" + b64[i : i + chunk] + b"\x07")
    w(b"\x1b]1337;FileEnd\x07")


def demo_basic() -> None:
    caption("basic — inline=1, auto size")
    png = make_png("basic")
    emit_file([("inline", "1"), ("size", str(len(png)))], png)
    print()


def demo_cells() -> None:
    caption("cells — width=20;height=8 (terminal cell units)")
    png = make_png("20x8 cells")
    emit_file(
        [("inline", "1"), ("width", "20"), ("height", "8"), ("size", str(len(png)))],
        png,
    )
    print()


def demo_pixels() -> None:
    caption("pixels — width=160px (converted to cells by the terminal)")
    png = make_png("160px wide")
    emit_file([("inline", "1"), ("width", "160px"), ("size", str(len(png)))], png)
    print()


def demo_percent() -> None:
    caption("percent — width=50% of the viewport")
    png = make_png("50% wide")
    emit_file([("inline", "1"), ("width", "50%"), ("size", str(len(png)))], png)
    print()


def demo_aspect() -> None:
    caption("aspect — preserveAspectRatio=0, forced 30x4 (stretched)")
    png = make_png("stretched")
    emit_file(
        [
            ("inline", "1"),
            ("width", "30"),
            ("height", "4"),
            ("preserveAspectRatio", "0"),
            ("size", str(len(png))),
        ],
        png,
    )
    print()


def demo_nocursor() -> None:
    caption("nocursor — doNotMoveCursor=1 (text prints right after the image)")
    png = make_png("no cursor move", w=120, h=48)
    emit_file(
        [
            ("inline", "1"),
            ("doNotMoveCursor", "1"),
            ("width", "10"),
            ("size", str(len(png))),
        ],
        png,
    )
    w(b"  <-- this text follows on the same row\n")


def demo_multipart() -> None:
    caption("multipart — MultipartFile / FilePart* / FileEnd (inline display)")
    png = make_png("multipart", w=260, h=140)
    emit_multipart(
        [("inline", "1"), ("width", "24"), ("size", str(len(png)))],
        png,
        chunk=512,
    )
    print()


def demo_download() -> None:
    caption("download — multipart inline=0 -> saved to $XDG_DOWNLOAD_DIR/Downloads")
    png = make_png("download", w=64, h=64)
    name_b64 = base64.b64encode(b"ghostty-osc1337-demo.png").decode("ascii")
    emit_multipart(
        [("inline", "0"), ("name", name_b64), ("size", str(len(png)))],
        png,
        chunk=512,
    )
    print("(check your Downloads directory for ghostty-osc1337-demo.png)")


DEMOS = {
    "basic": demo_basic,
    "cells": demo_cells,
    "pixels": demo_pixels,
    "percent": demo_percent,
    "aspect": demo_aspect,
    "nocursor": demo_nocursor,
    "multipart": demo_multipart,
    "download": demo_download,
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
