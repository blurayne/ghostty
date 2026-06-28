# Plan: Sixel Graphics Support
Date: 2026-06-28
Priority: P2
Status: implemented

## Goal

Add DEC sixel graphics rendering to the Ghostty fork. Sixel input is a DCS (Device Control String)
sequence that encodes a bitmap image as a series of "six-pixel tall" color bands. Many terminal
programs use it: gnuplot, imgcat-like tools, ImageMagick, yazi, lsix, viu, etc.

Upstream `ghostty-org/ghostty` explicitly removed sixel from their TODO. This fork adds it.

## Scope

**In scope:**
- Full DEC sixel grammar: palette introduction (`#n;2;r;g;b`), raster attributes (`"Pan;Pad;Ph;Pv`),
  color selection (`#n`), sixel data bands (printable bytes `?`–`~`), repetition prefix
  (`!n char`), carriage return (`$`), and next-line (`-`).
- Sixel parameters: aspect ratio params ignored (Ghostty renders at 1:1 cell resolution),
  color register count from Pc param, background fill from Ps param.
- Standard palette of up to 256 color registers.
- DCS hook recognition: `ESC P [params] q` (final byte `q`, no intermediates).
- Bridge approach: decode sixel → raw RGBA bitmap → upload to Kitty graphics pipeline
  (same approach used by the existing iTerm2 OSC 1337 bridge).
- Advertise sixel capability in DA1 response (feature bit 4).

**Out of scope (future work):**
- Transparent background (Ps=0 mode fully correct; partial transparency with palette index 0 reserved as transparent).
- Scrolling sixel display (images are placed at cursor and cursor advances past).
- Sixel cursor tracking/DECCRA interaction.
- Native renderer (not needed; Kitty pipeline handles all GPU rendering).

## Architecture Decision: Decode-to-Kitty Bridge

The iTerm2 OSC 1337 bridge (`stream_handler.zig:iterm2InlineImage`) already demonstrates the
pattern: decode image data → build `terminal.kitty.graphics.Command` with `.transmit_and_display`
→ call `self.terminal.kittyGraphics(self.alloc, &cmd)`. We use the same approach for sixel:

1. **DCS hook** triggers `sixel` state in `src/terminal/dcs.zig` when `final='q'`, `intermediates.len=0`.
2. **DCS put** bytes accumulate the raw sixel data stream in a growable buffer.
3. **DCS unhook** finalizes: the sixel buffer is decoded into RGBA pixels, then submitted to
   `kittyGraphics()` as format `.rgba` with explicit width/height.

Benefits:
- Zero new GPU/rendering code — Kitty pipeline handles display.
- Consistent with existing iTerm2 bridge; maintainable.
- Sixel parsing is pure Zig, no C library needed.
- Avoids writing a second image placement/scrolling system.

Drawback:
- Full sixel data must be buffered before display (no streaming display).
  This is acceptable; sixel images are typically <1MB.

## Files Touched

| File | Change |
|---|---|
| `src/terminal/dcs.zig` | Add `sixel` state and `Sixel` parser; add `Command.sixel` variant |
| `src/termio/stream_handler.zig` | Handle `.sixel` command in `dcsCommand`; advertise sixel in DA1 |
| `src/terminal/sixel.zig` | **New** — pure Zig sixel decoder: palette + bitmap rasterizer |

## Sixel Wire Format (Reference)

```
ESC P [Pa;Pb;Pc] q              — DCS header, final='q'
  "Pan;Pad;Ph;Pv                — optional raster attribute (aspect ratio + pixel dimensions)
  #n;2;r;g;b                   — define color register n (HLS mode: ;1; also exists)
  #n                            — select color register n
  ?..~ (possibly prefixed !n)  — sixel data bands (byte - 63 = 6-bit bitmask)
  $                            — carriage return (back to column 0, same row)
  -                            — next sixel row (cursor down 6 pixels)
ESC \                           — ST (string terminator)
```

## Sixel Decoder Design (`src/terminal/sixel.zig`)

```
pub const Decoder = struct {
    allocator: std.mem.Allocator,
    palette: [256]u32,           // RGBA colors (0xRRGGBBAA)
    pixels: std.ArrayListUnmanaged(u8),  // RGBA flat buffer
    width: u32,
    height: u32,
    cursor_x: u32,
    cursor_y: u32,         // current sixel band row (each band = 6 px tall)
    current_color: u8,
    pan: u32, pad: u32,   // aspect ratio (ignored for rendering)
    background_fill: bool, // from Ps param (0=default bg, 1=black bg)
    ...
};
```

Key operations:
- `init(alloc, ps, pc)` — initialize with Ps/Pc DCS params
- `feed(data: []const u8) !void` — process raw sixel bytes
- `toRgba() ![]u8` — return owned flat RGBA buffer (width*height*4 bytes)
- `deinit()` — free internal state

The `feed` function is a simple byte-at-a-time state machine:
- `#` → read palette entry or color selection
- `"` → read raster attributes
- `!` → read repeat count
- `$` → carriage return
- `-` → next band
- `?`..`~` → paint sixels

## DCS Handler Changes (`src/terminal/dcs.zig`)

Add `sixel` variant to `State` and `Command`:

```zig
pub const SixelParams = struct {
    ps: u16, // background select: 0=default, 1=black
    pc: u16, // color register count (0=256)
};

// State.sixel: accumulate raw bytes
sixel: struct {
    params: SixelParams,
    buffer: std.Io.Writer.Allocating,
    max_bytes: usize,
},

// Command.sixel
sixel: struct {
    params: SixelParams,
    data: std.Io.Writer.Allocating,
},
```

Recognition in `tryHook`:
```zig
0 => switch (dcs.final) {
    'q' => sixel: {
        // Pa;Pb;Pc q — sixel. Pa=aspect(ignored), Pb=bg, Pc=colors.
        const ps: u16 = if (dcs.params.len >= 2) dcs.params[1] else 0;
        const pc: u16 = if (dcs.params.len >= 3) dcs.params[2] else 0;
        break :sixel .{ .state = .{ .sixel = .{ .params = .{ .ps = ps, .pc = pc },
            .buffer = try .initCapacity(alloc, 4096),
            .max_bytes = self.max_bytes } } };
    },
    'p' => ..., // tmux
    else => null,
},
```

## StreamHandler Changes (`src/termio/stream_handler.zig`)

1. In `dcsCommand`: add `.sixel` arm that calls `sixelImage(params, data)`.
2. `sixelImage` function: mirrors `iterm2InlineImage`:
   - Guard on `kitty_graphics` feature.
   - Decode using `terminal.sixel.Decoder`.
   - Build `kitty.graphics.Command` with `.rgba` format, explicit `width`/`height`.
   - Call `kittyGraphics`.
3. In `deviceAttributes`: add `;4` to the DA1 response string to advertise sixel.

## Tests

- `src/terminal/sixel.zig` — unit tests for decoder:
  - Minimal 1×6 single-color sixel produces correct RGBA bytes.
  - Palette introduction and selection.
  - Repeat prefix `!n`.
  - Carriage return `$` and line feed `-`.
  - Raster attribute parsing.
- `src/terminal/dcs.zig` — DCS handler tests:
  - `tryHook` recognizes `final='q'` with no intermediates → `.sixel` state.
  - Unknown params still accepted (sixel has flexible params).
- `src/termio/stream_handler.zig` — integration:
  - DA1 response contains `;4`.

## Phases

1. **Phase 1** — Plan (this document).
2. **Phase 2** — Sixel decoder (`src/terminal/sixel.zig`) with unit tests.
3. **Phase 3** — DCS handler: `sixel` state + `Command.sixel`.
4. **Phase 4** — Stream handler: decode-to-kitty bridge + DA1 update.
5. **Phase 5** — Build verification (`mise run zig-build`).
6. **Phase 6** — Commit on `feat/sixel-support`.

## Edge Cases

- **Empty sixel body**: decoder returns 0×0 image; skip kitty upload.
- **Image larger than terminal**: Kitty pipeline clips to viewport.
- **>1MB data**: `max_bytes` on the DCS handler buffer drops remaining input (same as tmux/XTGETTCAP).
- **No kitty_graphics**: same comptime guard as iterm2; log debug and return.
- **Kitty images disabled at runtime**: `kitty_images.enabled()` check; skip silently.
- **Palette register overflow**: clamp to 0–255.
- **Aspect ratio params**: Pa=1 (2:1), Pa=2 (5:1) etc. — ignored; we paint at 1:1 and let the
  terminal cell rendering handle scaling naturally.

## References

- DEC STD 070: Sixel Graphics Extension
- https://vt100.net/docs/vt3xx-gp/chapter14.html (VT3xx sixel)
- https://www.vt100.net/docs/vt100-ug/chapter2.html (DCS structure)
- xterm sixel implementation (MIT): `xterm/sixel.c`
- libsixel by Hayaki Saito (MIT): https://github.com/saitoha/libsixel
- iTerm2 OSC 1337 bridge commit: `74a1d04cc`
