#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# ///
"""
Self-contained tester for the Glyph Protocol `fmt=glyf` path.

It probes the terminal for Glyph Protocol support, registers five Nerd Font
icon outlines (branch / folder / home / heart / Rust cog) at PUA-B codepoints
U+100000–U+100004 (and a `width=2` copy at U+100005–U+100009), then prints
them. On a Ghostty build with glyf rendering, the "glyf" rows render as real
icons; without it (or in another terminal) they show as tofu.

The base64 `glyf` payloads are the exact ones from
`raphamorim/glyph-protocol-examples` (extracted from JetBrainsMono Nerd Font,
upm=1000), so this mirrors that demo's glyf rows with no Rust/Go toolchain.

Run INSIDE the fork Ghostty (not tmux — see `test/glyph-protocol.sh doctor`).

Usage:
    test/glyph-protocol-glyf.py            # probe, register, print
    test/glyph-protocol-glyf.py clear      # clear all registrations
"""

import select
import sys
import termios
import tty

# glyf simple-glyph records, base64, upm=1000. Source Nerd Font codepoints:
#   branch U+E0A0, folder U+F07B, home U+F015, heart U+F004, rust U+E7A8
NERD_GLYFS_B64 = [
    "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",
]

LABELS = ["branch", "folder", "home", "heart", "rust"]
SLOT_CPS = [0x100000, 0x100001, 0x100002, 0x100003, 0x100004]
WIDE_SLOT_CPS = [0x100005, 0x100006, 0x100007, 0x100008, 0x100009]


def w(data: bytes) -> None:
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def probe_support(timeout_s: float = 0.3) -> list[str] | None:
    """Send `s` and read the reply's fmt= list. None on timeout/no-tty."""
    if not (sys.stdin.isatty() and sys.stdout.isatty()):
        return None
    fd = sys.stdin.fileno()
    saved = termios.tcgetattr(fd)
    try:
        tty.setraw(fd)
        w(b"\x1b_25a1;s\x1b\\")
        buf = bytearray()
        while b"\x1b\\" not in buf and len(buf) < 2048:
            r, _, _ = select.select([fd], [], [], timeout_s)
            if not r:
                break
            chunk = sys.stdin.buffer.read1(256)
            if not chunk:
                break
            buf += chunk
    finally:
        termios.tcsetattr(fd, termios.TCSADRAIN, saved)

    i = buf.find(b"fmt=")
    if i < 0:
        return None
    j = i + 4
    end = j
    while end < len(buf) and buf[end] not in (0x3B, 0x1B):  # ';' or ESC
        end += 1
    value = buf[j:end].decode("ascii", "replace")
    return value.split(",") if value else []


def register(cp: int, payload: str, wide: bool = False) -> None:
    width = ";width=2" if wide else ""
    seq = f"\x1b_25a1;r;cp={cp:x};reply=0;upm=1000{width};{payload}\x1b\\"
    w(seq.encode("ascii"))


def clear_all() -> None:
    w(b"\x1b_25a1;c\x1b\\")
    print("cleared all glyph registrations")


def icons(cps: list[int]) -> str:
    return "  ".join(chr(cp) for cp in cps)


def main() -> int:
    if sys.argv[1:2] == ["clear"]:
        clear_all()
        return 0

    fmts = probe_support()
    if fmts is None:
        print("No Glyph Protocol reply — not the fork Ghostty, or you're in a")
        print("multiplexer. Run `test/glyph-protocol.sh doctor` to find out which.")
        # Still attempt below; unsupporting terminals ignore the sequences.
        fmts = []
    print(f"terminal advertises fmt = {fmts or '(none)'}")

    has_glyf = "glyf" in fmts
    if has_glyf:
        for cp, payload in zip(SLOT_CPS, NERD_GLYFS_B64):
            register(cp, payload)
        for cp, payload in zip(WIDE_SLOT_CPS, NERD_GLYFS_B64):
            register(cp, payload, wide=True)
        sys.stdout.flush()

    print()
    print(f"labels        : {'   '.join(LABELS)}")
    if has_glyf:
        print(f"glyf icons    : {icons(SLOT_CPS)}   <- should be Nerd Font icons, not tofu")
        print(f"glyf wide     : {icons(WIDE_SLOT_CPS)}")
    else:
        print("glyf          : (glyf not advertised by this terminal)")
        print(f"raw PUA cps   : {icons(SLOT_CPS)}   <- tofu without glyf rendering")
    print()
    print("Run `test/glyph-protocol-glyf.py clear` to remove the registrations.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
