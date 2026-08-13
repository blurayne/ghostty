# Inline image protocol demos

Runnable examples for every inline-image protocol Ghostty implements. Each script generates a test image with Pillow and writes the appropriate terminal escape sequences to stdout. They are [uv single-file scripts](https://docs.astral.sh/uv/guides/scripts/) — the `#!/usr/bin/env -S uv run --script` shebang makes uv fetch Pillow into an ephemeral environment on first run, so no manual `pip install` is needed.

**Run them inside Ghostty.** They emit raw escape sequences; piping the output to a file or a non-graphics terminal just shows bytes. If you are inside `tmux`/`screen`, the sequences are intercepted before they reach Ghostty (enable passthrough or run outside the multiplexer).

| Script | Protocol | Framing |
|---|---|---|
| `iterm2_osc1337.py` | iTerm2 inline images | `ESC ] 1337 ; File=… : <base64> BEL` |
| `kitty_graphics.py` | Kitty graphics (Ghostty's native protocol) | `ESC _ G <keys> ; <base64> ESC \` |
| `sixel.py` | Sixel | `ESC P … q <sixel data> ESC \` |

## Usage

```sh
# full tour of each protocol's features
./iterm2_osc1337.py
./kitty_graphics.py
./sixel.py

# or a single feature (see each script's header for the list)
./iterm2_osc1337.py multipart
./kitty_graphics.py nocursor
./sixel.py bands
./sixel.py file path/to/image.png
```

## Notes

- **iTerm2 (`iterm2_osc1337.py`)** — this build decodes **PNG only**; other formats are detected by magic bytes and skipped. Single-shot `File=inline=1` displays; downloads (`inline=0` → `$XDG_DOWNLOAD_DIR`) go through the multipart `MultipartFile` / `FilePart` / `FileEnd` path (a single-shot `File=` with `inline=0`/`dispositionType=attachment` is intentionally ignored). Dimensions accept cells (`N`), pixels (`Npx`), percent (`N%`), or `auto`. See `src/terminal/osc/parsers/iterm2.zig`.
- **Kitty (`kitty_graphics.py`)** — supports PNG (`f=100`) and raw RGBA (`f=32`). Payloads are chunked at 4096 base64 bytes with `m=1`/`m=0`. See `src/terminal/kitty/`.
- **Sixel (`sixel.py`)** — the encoder quantises to a ≤256-colour adaptive palette and emits 6-pixel bands with run-length compression. See `src/terminal/sixel.zig`.

The Glyph Protocol (a fork-custom APC protocol for registering glyph outlines, not image display) has its own harness at `test/glyph-protocol.sh`.
