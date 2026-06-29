# Plan: iTerm2 Image Protocol (OSC 1337) — Remaining Features
Date: 2026-06-29
Priority: P2
Status: in-progress

## Goal

Complete the iTerm2 Inline Image Protocol (OSC 1337) image side beyond the basic `File=inline=1:`
case that was already implemented. The six target items are: multipart file transfer, `name=`
filename parsing, percent dimensions, `doNotMoveCursor`, `dispositionType`, and file download.

## Scope

**In scope:**
1. **Multipart file transfer** — `MultipartFile=<args>` initiates, `FilePart=<base64>` appends
   chunks, `FileEnd` finalizes. The assembled buffer is then processed like a `File=` payload.
2. **`name=` parsing** — base64-encoded filename field; used for download destination naming.
3. **Percent dimensions** — `width=50%` / `height=25%`. Store as a new discriminated union
   `DimKind` rather than adding more raw fields to `Iterm2InlineImage`. Pass percent values
   through to the stream handler which converts them to pixel counts at dispatch time using the
   known terminal viewport size.
4. **`doNotMoveCursor=1`** — map to `cursor_movement = .none` in the Kitty bridge instead of the
   hard-coded `.after`.
5. **`dispositionType=inline|attachment`** — treat `dispositionType=inline` as equivalent to
   `inline=1`; treat `dispositionType=attachment` as equivalent to `inline=0` (download path).
6. **File download** (`inline=0` / `dispositionType=attachment`) — write decoded payload to
   `$XDG_DOWNLOAD_DIR` (falling back to `$HOME/Downloads`), with the `name=` field (sanitized) as
   the filename. Log an `std.log.info` notification rather than sending a desktop notification;
   rationale: desktop notifications require a round-trip through the apprt layer and per-platform
   UX testing that is disproportionate to the value here, whereas a log line is universally
   visible and sufficient for a file-download side-effect.

**Out of scope (future work):**
- `SetBackgroundImageFile` — separate UI feature, own branch.
- Non-image OSC 1337 keys: `AddAnnotation`, `Block`, `OpenURL`, `SetBadgeFormat`, `StealFocus`,
  `RequestAttention`, profile/key-label stuff. These are not image protocol.
- Streaming sixel or iTerm2 images (full buffer required by Kitty bridge).
- Full desktop notification for download (see rationale above).

## Architecture Decisions

### A. Multipart State Location

The OSC 1337 parser (`parsers/iterm2.zig`) is called once per OSC sequence end. Multipart
transfers span *multiple* OSC sequences. The `Parser` struct in `osc.zig` resets between
sequences, so state cannot live there.

**Decision:** Add a `Iterm2MultipartState` struct to `StreamHandler` (in `termio/stream_handler.zig`).
The stream handler already persists across OSC sequences (unlike the parser). When the parser
produces an `iterm2_multipart_begin` command, the stream handler initialises the accumulation
buffer. `iterm2_file_part` commands append base64 data. `iterm2_file_end` finalises (decode +
display or download).

This requires three new `osc.Command` variants:
- `iterm2_multipart_begin: Iterm2MultipartBegin` — carries the header args (name, width, height,
  inline flag, preserveAspectRatio, doNotMoveCursor, dispositionType).
- `iterm2_file_part: []const u8` — raw base64 chunk (slice into the OSC parser's allocating
  buffer; copied by stream handler).
- `iterm2_file_end: void` — trigger finalisation.

Because these new commands carry data that the OSC parser owns (slices into its allocating buffer),
the stream handler must copy any data it needs before `reset()` is called by the terminal layer.

### B. Percent Dimensions

**Decision:** Extend `Iterm2InlineImage` (and the new `Iterm2MultipartBegin`) with two new fields:
`width_pct: u8` and `height_pct: u8` (0 = not specified). The stream handler converts percent to
pixels using `self.terminal.screen.pages.cols` × cell width and similarly for rows × cell height.
Kitty bridge then sees a pixel dimension.

Alternative considered: discriminated union for `Dim`. Rejected because it would make the struct
larger (union tag + padding) and the two-byte approach is simpler to carry across the C ABI
boundary (though `Iterm2InlineImage` already marks its C as void).

### C. Format Detection (Option A — PNG-only with format magic check)

The existing Kitty bridge passes `.format = .png` unconditionally. The wuffs PNG decoder in
`kitty/graphics_image.zig` will silently fail (log warning) for non-PNG data.

**Decision:** Option A — keep PNG-only, add a format magic-byte check in the stream handler's
`iterm2InlineImage` helper. If the magic bytes indicate non-PNG (JPEG `\xFF\xD8`, GIF `GIF8`,
WebP `RIFF...WEBP`, BMP `BM`), log a warning stating the format is unsupported and return early
rather than feeding garbage to the Kitty decoder.

Option B (stb_image decode + re-encode to PNG) was evaluated but rejected for this branch because:
- `src/stb/stb.c` is compiled with `#define STBI_ONLY_PNG`, so JPEG/GIF support is compiled out.
- Removing that define and adding a PNG re-encode step would pull in PNG write code (stb_image_write)
  which is not currently vendored.
- The work is non-trivial and out of scope for this branch.

Enabling multi-format support via stb_image is noted as future work.

### D. Download Path Resolution

`$XDG_DOWNLOAD_DIR` → fallback `$HOME/Downloads` → fallback temp dir. File is written with the
sanitized `name=` basename (path separators, `..`, and non-printable bytes stripped). If `name=`
is absent or empty after sanitization, use a generated name `iterm2-YYYYMMDD-HHMMSS.bin`.

### E. `name=` Encoding

Per the iTerm2 spec, `name=` is a base64-encoded filename. The parser will decode it with the
same `decodeBase64` helper and store the result as an owned slice (`[]u8`). The `Iterm2InlineImage`
struct gains a `name: ?[]u8 = null` field.

## Files Touched

| File | Change |
|---|---|
| `src/terminal/osc.zig` | Add `iterm2_multipart_begin`, `iterm2_file_part`, `iterm2_file_end` command variants; extend `Iterm2InlineImage` struct with `name`, `width_pct`, `height_pct`, `do_not_move_cursor` |
| `src/terminal/osc/parsers/iterm2.zig` | Parse `name=`, `%` dimensions, `doNotMoveCursor`, `dispositionType`; implement `MultipartFile`, `FilePart`, `FileEnd` branches |
| `src/terminal/stream.zig` | Add the three new command keys to the `Command.Key` enum wiring |
| `src/terminal/stream_terminal.zig` | No-op stubs for the three new multipart commands |
| `src/termio/stream_handler.zig` | Handle `iterm2_multipart_begin`/`iterm2_file_part`/`iterm2_file_end`; update `iterm2InlineImage` for `doNotMoveCursor`, percent dims, format magic check; add `iterm2_download` helper; add `Iterm2MultipartState` field |

## Phases

1. **Phase 1** — Plan (this document). ✓
2. **Phase 2** — Extend `Iterm2InlineImage` struct and `osc.zig` command enum.
3. **Phase 3** — Parser (`iterm2.zig`): `name=`, `%` dims, `doNotMoveCursor`, `dispositionType`,
   multipart command emission.
4. **Phase 4** — Stream handler: `iterm2InlineImage` improvements (format magic, `doNotMoveCursor`,
   percent dims, format check) + download helper + multipart state machine.
5. **Phase 5** — Wire new commands through `stream.zig` and `stream_terminal.zig`.
6. **Phase 6** — Unit tests: multipart assembly, percent dims, `doNotMoveCursor`,
   `dispositionType`, download filename sanitization.
7. **Phase 7** — Build verification (`mise run zig-build`). Parser tests pass.
8. **Phase 8** — Commit on `feat/iterm2-image-protocol`.

## Test Approach

All tests live in `src/terminal/osc/parsers/iterm2.zig` (parser-level) and a new
`src/termio/iterm2_download_test.zig` (download path sanitization, isolated from apprt).

Parser tests (run with `-Dtest-filter='OSC: 1337'`):
- `MultipartFile=` produces `iterm2_multipart_begin` with correct parsed fields.
- `FilePart=<b64>` produces `iterm2_file_part` with correct data.
- `FileEnd` produces `iterm2_file_end`.
- `width=50%` → `width_pct=50`, `width_px=0`, `columns=0`.
- `doNotMoveCursor=1` → `do_not_move_cursor=true`.
- `dispositionType=inline` accepted like `inline=1`.
- `dispositionType=attachment` → produces download command (inline=false).
- `name=dGVzdC5wbmc=` (base64 "test.png") → `name = "test.png"`.

## Edge Cases

- `FilePart` or `FileEnd` with no preceding `MultipartFile` → log warning, ignore.
- Empty `name=` after decode → generate timestamp-based filename.
- `name=` containing `../`, absolute path components → stripped to basename only.
- Non-PNG image data in `File=inline=1:` → log warning, skip Kitty upload.
- `width=0%` or `height=101%` → treated as auto (0).
- Multipart buffer exceeds a cap (e.g., 32 MB) → abort, log warning.
- Download to `$XDG_DOWNLOAD_DIR` fails → log error, do not crash.

## References

- https://iterm2.com/documentation-images.html
- https://iterm2.com/documentation-escape-codes.html
- `src/terminal/osc/parsers/iterm2.zig` — existing parser
- `src/termio/stream_handler.zig:378` — existing `iterm2InlineImage` bridge
- `src/terminal/kitty/graphics_command.zig` — `CursorMovement` enum
- `docs/agents/plans/2026-06-28-sixel-support.md` — style reference
