# Paste clipboard image as temp-file path — Design

Date: 2026-06-30
Status: Approved (design); pending implementation plan

## Summary

When the clipboard holds an image and the user pastes, Ghostty saves the image
to a temporary PNG file and **types the file path into the running program as a
bracketed paste**. Nothing is rendered inline. This makes path-aware CLIs (most
notably the `claude` CLI) receive the image through their existing
"auto-attach an image file path" behavior, robustly and without depending on the
CLI's own (flaky on Linux) clipboard reader.

Text paste behavior is unchanged.

## Motivation & background

Pasting a clipboard image into a CLI program does **not** send image bytes
through the PTY — no terminal does this. In iTerm2 + Claude CLI, the image
reaches Claude because **Claude reads the OS clipboard itself** (`osascript` /
NSPasteboard) when it sees the paste keystroke; iTerm2 only forwards a keypress.
On Linux this path is fragile (depends on `xclip`/`wl-paste` being installed, the
right format, detection not being cached, etc.).

The robust, terminal-side alternative — already used by WezTerm and kitty users
specifically to make Claude image-paste work on Linux — is: on image paste, the
**terminal** saves the bitmap to a temp file and **types the file path** as a
bracketed paste. Claude (and other path-aware tools) auto-detect image file paths
(`.png/.jpg/...`) and attach them, showing the `[Image #1]` placeholder. This is
what this feature implements. It is more reliable than the iTerm2 approach
because it does not rely on the CLI's clipboard reader at all.

References (background, not normative):
- claude-code #29776 (Claude reads clipboard via osascript), #12486 / #67486
  (Linux clipboard fragility).
- WezTerm save-and-type-path recipe; kitty `clip2path` / Linux fix script.

## Goals

- Pasting an image saves it to a temp PNG and types the path (bracketed paste).
- Works for `claude` CLI: produces an `[Image #1]` attachment.
- Text paste unchanged.
- Cross-platform core; GTK/Linux is the primary, tested target. macOS implements
  the same apprt hook.

## Non-goals

- No inline image rendering (explicitly chosen — avoids corrupting full-screen
  TUIs like Claude, which redraw over injected graphics).
- No remote/SSH support in v1 (temp file is written locally).
- No new image transport protocol (OSC 5522 etc.).

## Design

### 1. Action + config

`src/input/Binding.zig`:
- New action **`paste_image`** (no args), unbound by default. Always forces the
  image-paste path.
- `paste_from_clipboard` and `paste_from_selection` gain **auto-detect**: if the
  clipboard offers an image target and no text target, route to image paste;
  otherwise behave as today (text).
  - **Multi-format default**: when the clipboard offers *both* image and text,
    the normal paste binding pastes **text** (least surprising, matches current
    behavior). `paste_image` overrides and forces the image. Screenshots are
    image-only, so the common case needs no override.

`src/config/Config.zig` (naming consistent with existing `clipboard-paste-*`):
- `clipboard-image-paste` (bool, default `true`) — master enable. When `false`,
  image paste is disabled and an image-only clipboard pastes nothing (or the text
  fallback if present).
- `clipboard-image-paste-directory` (string, default `""` → OS temp dir; `/tmp`
  on Linux) — where temp PNGs are written.
- `clipboard-image-paste-max-size` (int bytes, default `25_000_000`) — images
  larger than this are rejected (avoid PTY/parser abuse and runaway temp files).

### 2. Cross-platform clipboard image read

`src/apprt/structs.zig`:
- Extend the clipboard abstraction with an **image clipboard request** whose
  completion carries **PNG bytes**. The apprt is responsible for normalizing
  whatever the OS clipboard holds into PNG.

GTK (`src/apprt/gtk/class/surface.zig`):
- Detection: inspect `gdk_clipboard_get_formats()` for an image MIME type
  (e.g. `image/png`) before choosing the image path.
- Read: `gdk_clipboard_read_texture_async` → `GdkTexture.save_to_png_bytes()`
  (handles non-PNG sources by re-encoding to PNG).

macOS (`macos/`):
- `NSPasteboard` → read image, encode PNG. Same apprt hook as GTK. GTK is the
  primary tested target; macOS mirrors the contract.

### 3. Core handling

`src/Surface.zig` — new `completeClipboardPasteImage(png_bytes)`:
1. Enforce `clipboard-image-paste-max-size`; reject oversize (log/notify, no
   write).
2. Write `<dir>/ghostty-paste-<timestamp>-<rand>.png`.
   - Name is space-free → no shell quoting needed.
   - `timestamp` + `rand` suffix avoids same-second collisions.
   - Best-effort prune of stale `ghostty-paste-*` files older than 24h in the
     same directory.
3. Encode the path through the existing `input.paste.encode`
   (`src/input/paste.zig`, bracketed-paste aware) and queue it to PTY stdin via
   `termio.Message.writeReq` / `queueIo` — exactly the existing text-paste write
   path. No trailing newline (must not submit the line).

No new termio message, no `processOutput` injection, no Kitty graphics — the
image is delivered purely as a typed path.

### Data flow

```
paste pressed
 └─ apprt checks clipboard targets
      ├─ text  → existing text paste (unchanged)
      └─ image → readClipboardImage() → PNG bytes → core
           ├─ enforce max-size
           ├─ save  <dir>/ghostty-paste-<ts>-<rand>.png      (the deliverable)
           └─ encode(path, bracketed) ──writeReq──▶ PTY stdin
                                                    ▶ claude auto-attaches → "[Image #1]"
```

## Caveats (documented behavior, not bugs)

- **SSH/remote**: the temp file is written on the **local** machine; a remote
  shell receives a path that does not exist remotely. v1 is local-only.
- **Path-unaware programs**: a plain shell simply gets the path typed on the
  command line — still a reasonable outcome (`cat`, `feh`, image tools can use
  it).
- **No inline preview** — intentional; avoids any TUI corruption.

## Testing

Unit:
- Temp-filename generation (uniqueness, space-free, `.png` extension, configured
  directory honored).
- Size-cap rejection (oversize input is not written and produces no paste).
- `paste.encode` of the path with and without bracketed-paste mode.

Integration:
- Feed PNG bytes to `completeClipboardPasteImage` and assert: (a) a temp file is
  written with the expected name pattern, (b) a `writeReq` is queued carrying the
  bracketed-wrapped path (when bracketed mode is on) / the bare path (when off).

Manual:
- Paste a screenshot into `claude` running in Ghostty → `[Image #1]` appears and
  the image is attached.
- Paste an image at a shell prompt → the temp path appears on the command line.
- Oversize image → rejected, nothing pasted.
- Text paste → unchanged.

## Open defaults (chosen, changeable)

- Multi-format clipboard default = **text** (override via `paste_image`).
- Temp directory default = OS temp (`/tmp` on Linux).
- Max size = **25 MB**.
