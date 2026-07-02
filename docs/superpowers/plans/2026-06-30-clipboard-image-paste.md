# Clipboard Image Paste Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When the clipboard holds an image, pasting saves it to a temporary PNG and types the file path into the running program (bracketed paste), so path-aware CLIs (e.g. `claude`) receive the image; text paste is unchanged.

**Architecture:** The apprt (GTK) reads the clipboard image and normalizes it to PNG bytes, then hands the bytes to a new cross-platform core method `Surface.completeClipboardPasteImage`. Core writes a temp file via a small pure helper (`apprt/clipboard_image.zig`) and reuses the existing `completeClipboardPaste` pipeline to paste the file path. A new `paste_image` keybind action forces this path; the normal paste action auto-detects an image when no text is present. No image is rendered inline.

**Tech Stack:** Zig, GTK4 via zig gobject bindings (GDK clipboard + `GdkTexture.saveToPngBytes`), the existing Ghostty termio paste pipeline.

## Global Constraints

- **All builds and tests run inside the dev container via mise.** Never run `zig build` directly on the host.
  - Fast compile check: `mise run zig-build`
  - Unit tests: `ZIG_ARGS='-Dtest-filter=<filter>' mise run zig-test`
  - Full flatpak build: `mise run build` — then install with `mise run install`
- **Implementer model:** Sonnet.
- **Scope:** GTK/Linux is the fully-implemented, tested target. macOS gets only the compile-time seam (a stub returning `false`); a real macOS/NSPasteboard implementation is explicit follow-up work, not part of this plan.
- Run `zig fmt .` (inside the container shell) before each commit.
- Feature branch: `feat/clipboard-image-paste` (already checked out; the design spec is already committed there).
- Config option defaults (copy verbatim): `clipboard-image-paste = true`, `clipboard-image-paste-directory = null` (→ `$TMPDIR` or `/tmp`), `clipboard-image-paste-max-size = 25_000_000`.
- Temp file naming: `ghostty-paste-<timestamp_ms>-<rand_u32>.png`.
- Multi-format clipboard (image + text present): normal paste → **text**; `paste_image` action → **image**.

---

### Task 1: Config options + DerivedConfig wiring

**Files:**
- Modify: `src/config/Config.zig:2449` (add options after `clipboard-paste-bracketed-safe`)
- Modify: `src/Surface.zig:301` (DerivedConfig fields) and `src/Surface.zig:380` (DerivedConfig init)
- Test: `src/config/Config.zig` (inline test)

**Interfaces:**
- Produces (config fields): `config.@"clipboard-image-paste": bool`, `config.@"clipboard-image-paste-directory": ?[]const u8`, `config.@"clipboard-image-paste-max-size": u32`
- Produces (DerivedConfig fields, accessed as `self.config.<name>` on core `Surface`): `clipboard_image_paste: bool`, `clipboard_image_paste_directory: ?[]const u8`, `clipboard_image_paste_max_size: u32`

- [x] **Step 1: Write the failing test**

Add to the end of `src/config/Config.zig` (before the final line if there's a trailing block, otherwise append):

```zig
test "clipboard image paste defaults" {
    const testing = std.testing;
    var cfg = try Config.default(testing.allocator);
    defer cfg.deinit();
    try testing.expect(cfg.@"clipboard-image-paste");
    try testing.expectEqual(@as(?[]const u8, null), cfg.@"clipboard-image-paste-directory");
    try testing.expectEqual(@as(u32, 25_000_000), cfg.@"clipboard-image-paste-max-size");
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `ZIG_ARGS='-Dtest-filter=clipboard image paste defaults' mise run zig-test`
Expected: FAIL — compile error, `clipboard-image-paste` is not a member of `Config`.

- [x] **Step 3: Add the config options**

In `src/config/Config.zig`, immediately after the `@"clipboard-paste-bracketed-safe": bool = true,` line (currently line 2449):

```zig
/// Enable pasting images from the clipboard. When enabled, pasting while the
/// clipboard holds an image (and no text) saves the image to a temporary PNG
/// file and pastes that file's path into the running program (as a bracketed
/// paste). This lets CLI tools that understand image file paths (for example,
/// coding agents) receive the image. No image is rendered inline.
///
/// The dedicated `paste_image` keybind action always uses this path, even when
/// the clipboard also contains text.
@"clipboard-image-paste": bool = true,

/// Directory to write clipboard images into for `clipboard-image-paste`. When
/// unset, the system temporary directory is used (`$TMPDIR` or `/tmp` on
/// Linux). Files are named `ghostty-paste-<n>.png`.
@"clipboard-image-paste-directory": ?[]const u8 = null,

/// Maximum size in bytes of a clipboard image that will be pasted via
/// `clipboard-image-paste`. Larger images are ignored. Guards against writing
/// very large temporary files.
@"clipboard-image-paste-max-size": u32 = 25_000_000,
```

- [x] **Step 4: Add DerivedConfig fields**

In `src/Surface.zig`, in the `DerivedConfig` struct after `clipboard_paste_bracketed_safe: bool,` (currently line 301):

```zig
    clipboard_image_paste: bool,
    clipboard_image_paste_directory: ?[]const u8,
    clipboard_image_paste_max_size: u32,
```

- [x] **Step 5: Copy values in DerivedConfig.init**

In `src/Surface.zig`, in the DerivedConfig initializer after `.clipboard_paste_bracketed_safe = config.@"clipboard-paste-bracketed-safe",` (currently line 380):

```zig
            .clipboard_image_paste = config.@"clipboard-image-paste",
            .clipboard_image_paste_directory = if (config.@"clipboard-image-paste-directory") |dir|
                try alloc.dupe(u8, dir)
            else
                null,
            .clipboard_image_paste_max_size = config.@"clipboard-image-paste-max-size",
```

- [x] **Step 6: Run test to verify it passes**

Run: `ZIG_ARGS='-Dtest-filter=clipboard image paste defaults' mise run zig-test`
Expected: PASS

- [x] **Step 7: Commit**

```bash
zig fmt .
git add src/config/Config.zig src/Surface.zig
git commit -m "feat(config): add clipboard-image-paste options

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Temp-file helper (`apprt/clipboard_image.zig`)

Pure, fully unit-testable helper that builds the file name and writes the PNG.

**Files:**
- Create: `src/apprt/clipboard_image.zig`
- Modify: `src/apprt.zig:54` (register module + its tests)
- Test: `src/apprt/clipboard_image.zig` (inline tests)

**Interfaces:**
- Produces:
  - `pub const prefix = "ghostty-paste-";`
  - `pub fn resolveDir(dir: ?[]const u8) []const u8`
  - `pub fn fileName(buf: []u8, timestamp_ms: i64, rand: u32) []const u8`
  - `pub fn write(alloc: std.mem.Allocator, dir: ?[]const u8, png: []const u8, timestamp_ms: i64, rand: u32) ![]u8` — returns caller-owned absolute path.
- Consumers reach it as `apprt.clipboard_image.<fn>` (registered in Step 3).

- [x] **Step 1: Create the file with the failing tests**

Create `src/apprt/clipboard_image.zig`:

```zig
//! Helpers for the "paste clipboard image as a temp-file path" feature.
//! These build and write the temporary PNG file whose path is then pasted
//! into the running program. See docs/superpowers/specs for the design.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// Prefix for all temp files we create. Used for both creation and (future)
/// pruning.
pub const prefix = "ghostty-paste-";

/// Resolve the directory to write clipboard images into. If `dir` is non-null
/// it is returned as-is; otherwise the system temp dir is used.
pub fn resolveDir(dir: ?[]const u8) []const u8 {
    return dir orelse (std.posix.getenv("TMPDIR") orelse "/tmp");
}

/// Format the file name (not the full path) for a clipboard image into `buf`.
/// Returns the slice of `buf` that was written. `buf` must be at least
/// 64 bytes.
pub fn fileName(buf: []u8, timestamp_ms: i64, rand: u32) []const u8 {
    return std.fmt.bufPrint(
        buf,
        prefix ++ "{d}-{d}.png",
        .{ timestamp_ms, rand },
    ) catch unreachable;
}

/// Write `png` to a new temp file in `dir` (or the system temp dir if null).
/// Returns the absolute file path, allocated with `alloc`; caller owns it.
pub fn write(
    alloc: Allocator,
    dir: ?[]const u8,
    png: []const u8,
    timestamp_ms: i64,
    rand: u32,
) ![]u8 {
    const base = resolveDir(dir);

    var name_buf: [64]u8 = undefined;
    const name = fileName(&name_buf, timestamp_ms, rand);

    const path = try std.fs.path.join(alloc, &.{ base, name });
    errdefer alloc.free(path);

    const file = try std.fs.cwd().createFile(path, .{ .truncate = true });
    defer file.close();
    try file.writeAll(png);

    return path;
}

test "clipboard image: fileName format" {
    var buf: [64]u8 = undefined;
    const name = fileName(&buf, 1234, 56);
    try std.testing.expectEqualStrings("ghostty-paste-1234-56.png", name);
}

test "clipboard image: write creates png file with bytes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(dir_path);

    const png = "\x89PNG\r\n\x1a\nDATA";
    const path = try write(testing.allocator, dir_path, png, 999, 7);
    defer testing.allocator.free(path);

    try testing.expect(std.mem.endsWith(u8, path, "ghostty-paste-999-7.png"));

    const contents = try std.fs.cwd().readFileAlloc(testing.allocator, path, 1024);
    defer testing.allocator.free(contents);
    try testing.expectEqualStrings(png, contents);
}
```

- [x] **Step 2: Register the module so its tests run**

In `src/apprt.zig`, add a top-level declaration near the other `const`/`pub const` imports (top of file):

```zig
pub const clipboard_image = @import("clipboard_image.zig");
```

Then add it to the test block at `src/apprt.zig:54`:

```zig
test {
    _ = Runtime;
    _ = runtime;
    _ = action;
    _ = structs;
    _ = clipboard_image;
}
```

- [x] **Step 3: Run tests to verify they pass**

Run: `ZIG_ARGS='-Dtest-filter=clipboard image:' mise run zig-test`
Expected: PASS (2 tests: `fileName format`, `write creates png file with bytes`)

- [x] **Step 4: Commit**

```bash
zig fmt .
git add src/apprt/clipboard_image.zig src/apprt.zig
git commit -m "feat(apprt): add clipboard image temp-file helper

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `paste_image` action + core `completeClipboardPasteImage`

Adds the keybind action, the action→request dispatch, and the core method that turns PNG bytes into a pasted path. The apprt seam method it calls is added in Task 4, so this task ends by compiling only after Task 4 — therefore we split the compile-verified deliverable: here we add the action enum + parse test + the core method body that references `self.rt_surface.clipboardRequestImage`. Build verification happens at the end of Task 4.

**Files:**
- Modify: `src/input/Binding.zig:379` (enum), `src/input/Binding.zig:1382` (scope), `src/input/command.zig:184` (command palette)
- Modify: `src/Surface.zig:5105` (action dispatch), `src/Surface.zig:5886` (add `startClipboardRequestImage`), `src/Surface.zig:5965` (add `completeClipboardPasteImage`)
- Test: `src/input/Binding.zig` (inline parse test)

**Interfaces:**
- Consumes (from Task 1): `self.config.clipboard_image_paste`, `self.config.clipboard_image_paste_directory`, `self.config.clipboard_image_paste_max_size`
- Consumes (from Task 2): `apprt.clipboard_image.write(...)`
- Consumes (from Task 4, added next): `self.rt_surface.clipboardRequestImage(loc: apprt.Clipboard) !bool`
- Produces: enum `Action.paste_image`; `Surface.completeClipboardPasteImage(self: *Surface, png: []const u8) !void` (public, called by apprts).

- [x] **Step 1: Write the failing test**

Add to `src/input/Binding.zig` near the other action parse tests (search for an existing `test "parse` block and add after it):

```zig
test "parse paste_image action" {
    const testing = std.testing;
    try testing.expect((try Action.parse("paste_image")) == .paste_image);
}
```

- [x] **Step 2: Run test to verify it fails**

Run: `ZIG_ARGS='-Dtest-filter=parse paste_image action' mise run zig-test`
Expected: FAIL — `paste_image` is not a member of `Action`.

- [x] **Step 3: Add the enum value**

In `src/input/Binding.zig`, after `paste_from_selection,` (line 379):

```zig
    /// Paste an image from the default clipboard, if one is present. The image
    /// is written to a temporary file and its path is pasted into the running
    /// program. See the `clipboard-image-paste` config option.
    paste_image,
```

- [x] **Step 4: Add to the `scope()` switch**

In `src/input/Binding.zig`, in the surface-actions list, after `.paste_from_selection,` (line 1382):

```zig
            .paste_image,
```

- [x] **Step 5: Add the command-palette entry**

In `src/input/command.zig`, after the `.paste_from_selection => ...` block (ends line 184):

```zig
        .paste_image => comptime &.{.{
            .action = .paste_image,
            .title = "Paste Image from Clipboard",
            .description = "Paste an image from the clipboard as a temporary file path.",
        }},
```

- [x] **Step 6: Run the parse test to verify it passes**

Run: `ZIG_ARGS='-Dtest-filter=parse paste_image action' mise run zig-test`
Expected: PASS

- [x] **Step 7: Add the action dispatch**

In `src/Surface.zig`, after the `.paste_from_selection => ...` arm (ends line 5105):

```zig
        .paste_image => return try self.startClipboardRequestImage(.standard),
```

- [x] **Step 8: Add `startClipboardRequestImage`**

In `src/Surface.zig`, immediately after the `startClipboardRequest` function (ends line 5886):

```zig
/// Start an image clipboard request (for the `paste_image` action). Returns
/// true if a request was started. Returns false if image paste is disabled or
/// the apprt does not support it, so performable keybinds can pass through.
fn startClipboardRequestImage(
    self: *Surface,
    loc: apprt.Clipboard,
) !bool {
    if (!self.config.clipboard_image_paste) return false;
    return try self.rt_surface.clipboardRequestImage(loc);
}
```

- [x] **Step 9: Add `completeClipboardPasteImage`**

In `src/Surface.zig`, immediately after the `completeClipboardPaste` function (ends line 5965):

```zig
/// Complete an image clipboard paste. `png` is the raw PNG-encoded image bytes
/// read from the clipboard by the apprt. We write the image to a temp file and
/// paste its path into the terminal (see the `clipboard-image-paste` config).
/// The data is copied as needed; it is safe to free `png` after this returns.
pub fn completeClipboardPasteImage(
    self: *Surface,
    png: []const u8,
) !void {
    if (!self.config.clipboard_image_paste) {
        log.info("clipboard image paste disabled, ignoring", .{});
        return;
    }
    if (png.len == 0) return;
    if (png.len > self.config.clipboard_image_paste_max_size) {
        log.warn(
            "clipboard image too large, ignoring len={} max={}",
            .{ png.len, self.config.clipboard_image_paste_max_size },
        );
        return;
    }

    const path = try apprt.clipboard_image.write(
        self.alloc,
        self.config.clipboard_image_paste_directory,
        png,
        std.time.milliTimestamp(),
        std.crypto.random.int(u32),
    );
    defer self.alloc.free(path);

    log.info("clipboard image written to {s}", .{path});

    // Paste the path through the normal (safe) paste path so it is bracketed
    // when the running program has bracketed paste mode enabled. allow_unsafe
    // is true because the path we generated is known-safe and we never want a
    // confirmation dialog for it.
    try self.completeClipboardPaste(path, true);
}
```

- [x] **Step 10: Commit (compiles after Task 4)**

```bash
zig fmt .
git add src/input/Binding.zig src/input/command.zig src/Surface.zig
git commit -m "feat(core): add paste_image action and completeClipboardPasteImage

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: apprt seam — `clipboardRequestImage`

Adds the runtime-surface method to every apprt so core compiles. GTK routes to the class implementation (Task 5); embedded (macOS) is a stub returning `false`.

**Files:**
- Modify: `src/apprt/gtk/Surface.zig:82` (after `clipboardRequest`)
- Modify: `src/apprt/embedded.zig:698` (after `clipboardRequest`)

**Interfaces:**
- Produces: `clipboardRequestImage(self, clipboard_type: apprt.Clipboard) !bool` on each apprt runtime `Surface`.
- Consumes (GTK, added in Task 5): the class-level `Surface.clipboardRequestImage`.

- [x] **Step 1: Add the GTK thin-wrapper method**

In `src/apprt/gtk/Surface.zig`, after the `clipboardRequest` function (ends line 82):

```zig
pub fn clipboardRequestImage(
    self: *Self,
    clipboard_type: apprt.Clipboard,
) !bool {
    return try self.surface.clipboardRequestImage(clipboard_type);
}
```

- [x] **Step 2: Add the embedded (macOS) stub**

In `src/apprt/embedded.zig`, after the `clipboardRequest` function (ends line 698):

```zig
pub fn clipboardRequestImage(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
) !bool {
    _ = self;
    _ = clipboard_type;
    // Image clipboard paste is not yet implemented for this apprt (macOS).
    // See the clipboard-image-paste config option and the design spec.
    return false;
}
```

- [x] **Step 3: Verify it compiles**

Run: `mise run zig-build`
Expected: build succeeds (note: `self.surface.clipboardRequestImage` in the GTK wrapper resolves once Task 5 adds the class method — if building this task in isolation before Task 5, temporarily expect an "unknown method" error on the GTK line; proceed to Task 5 then build). If you are executing tasks in order, do Task 5 before running this build.

- [x] **Step 4: Commit**

```bash
zig fmt .
git add src/apprt/gtk/Surface.zig src/apprt/embedded.zig
git commit -m "feat(apprt): add clipboardRequestImage seam (gtk + embedded stub)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: GTK image read implementation

Reads a clipboard texture, encodes PNG, and calls core `completeClipboardPasteImage`.

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig:1755` (public class method, near `clipboardRequest`)
- Modify: `src/apprt/gtk/class/surface.zig:4226` (add `requestImage` + `clipboardReadTexture` in the `Clipboard` namespace)

**Interfaces:**
- Consumes: `apprt.Clipboard`, the existing `Clipboard.get`, `Request` struct, GDK `readTextureAsync`/`readTextureFinish`, `gdk.Texture.saveToPngBytes`, `glib.Bytes.getData`, core `Surface.completeClipboardPasteImage`.
- Produces: `Surface.clipboardRequestImage(self, clipboard_type) !bool` (class-level, called by Task 4's wrapper); `Clipboard.requestImage` (called by Task 6's auto-detect).

- [x] **Step 1: Add the public class method**

In `src/apprt/gtk/class/surface.zig`, next to the existing `pub fn clipboardRequest` (around line 1748-1755), add:

```zig
pub fn clipboardRequestImage(
    self: *Surface,
    clipboard_type: apprt.Clipboard,
) !bool {
    return Clipboard.requestImage(self, clipboard_type);
}
```

- [x] **Step 2: Add `requestImage` + `clipboardReadTexture` to the `Clipboard` namespace**

In `src/apprt/gtk/class/surface.zig`, inside the `const Clipboard = struct { ... }` namespace, after the `request` function (ends line 4226), add:

```zig
    /// Request an image from the clipboard, write it to a temp file, and paste
    /// the path. Returns true if a read was started, false if the clipboard
    /// has no image (so performable keybinds can pass through).
    pub fn requestImage(
        self: *Surface,
        clipboard_type: apprt.Clipboard,
    ) Allocator.Error!bool {
        const clipboard = get(
            self.private().gl_area.as(gtk.Widget),
            clipboard_type,
        ) orelse return false;

        // Only start if the clipboard actually offers a PNG image.
        const formats = clipboard.getFormats();
        if (formats.containMimeType("image/png") == 0) {
            log.debug("clipboard has no image format, not starting image paste", .{});
            return false;
        }

        const alloc = Application.default().allocator();
        const ud = try alloc.create(Request);
        errdefer alloc.destroy(ud);
        ud.* = .{
            .self = self.ref(),
            .state = .{ .paste = {} },
        };
        errdefer self.unref();

        clipboard.readTextureAsync(
            null,
            clipboardReadTexture,
            ud,
        );

        return true;
    }

    fn clipboardReadTexture(
        source: ?*gobject.Object,
        res: *gio.AsyncResult,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const clipboard = gobject.ext.cast(
            gdk.Clipboard,
            source orelse return,
        ) orelse return;
        const req: *Request = @ptrCast(@alignCast(ud orelse return));

        const alloc = Application.default().allocator();
        defer alloc.destroy(req);

        const self = req.self;
        defer self.unref();

        var gerr: ?*glib.Error = null;
        const texture_ = clipboard.readTextureFinish(res, &gerr);
        if (gerr) |err| {
            defer err.free();
            log.warn(
                "failed to read clipboard image err={s}",
                .{err.f_message orelse "(no message)"},
            );
            return;
        }
        const texture = texture_ orelse return;
        defer texture.unref();

        // Encode the texture to PNG bytes.
        const bytes = texture.saveToPngBytes();
        defer bytes.unref();

        var size: usize = 0;
        const data_ptr = bytes.getData(&size) orelse return;
        const png = @as([*]const u8, @ptrCast(data_ptr))[0..size];

        const surface = self.private().core_surface orelse return;
        surface.completeClipboardPasteImage(png) catch |err| {
            log.warn("failed to complete image paste err={}", .{err});
            return;
        };
    }
```

- [x] **Step 3: Verify it compiles**

Run: `mise run zig-build`
Expected: build succeeds.

- [x] **Step 4: Full build + install**

Run:
```bash
mise run build
mise run install
```
Expected: flatpak builds and installs. (Poll the build output every 15s per the polling guidance; the first build may download the runtime.)

- [ ] **Step 5: Manual verification — explicit action**

Add a temporary keybind to your Ghostty config (`~/.config/ghostty/config` or the flatpak config path), e.g.:
```
keybind = ctrl+shift+i=paste_image
```
Copy a screenshot to the clipboard (image only), open Ghostty, at a shell prompt press `Ctrl+Shift+I`.
Expected: a path like `/tmp/ghostty-paste-<n>-<n>.png` appears on the command line, and the file exists (`ls -la /tmp/ghostty-paste-*.png`; `file` reports PNG of the right dimensions).

- [ ] **Step 6: Manual verification — Claude CLI**

Run `claude` in Ghostty, copy a screenshot, press `Ctrl+Shift+I`.
Expected: Claude shows an `[Image #N]` attachment (it auto-attaches the pasted image path).

- [x] **Step 7: Commit**

```bash
zig fmt .
git add src/apprt/gtk/class/surface.zig
git commit -m "feat(gtk): read clipboard image and paste temp-file path

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: Auto-detect image on the normal paste action

Makes `paste_from_clipboard`/`paste_from_selection` route to image paste when the clipboard has an image and no text (and image paste is enabled).

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig:4198-4204` (the `if (state == .paste)` block inside `Clipboard.request`)

**Interfaces:**
- Consumes: `Clipboard.requestImage` (Task 5), `self.private().core_surface.?.config.clipboard_image_paste`, `formats.containMimeType`.

- [x] **Step 1: Replace the no-text early return with image auto-detect**

In `src/apprt/gtk/class/surface.zig`, replace the existing block (currently lines 4198-4204):

```zig
        if (state == .paste) {
            const formats = clipboard.getFormats();
            if (formats.containGtype(gobject.ext.types.string) == 0) {
                log.debug("clipboard has no text format, not starting paste request", .{});
                return false;
            }
        }
```

with:

```zig
        if (state == .paste) {
            const formats = clipboard.getFormats();
            if (formats.containGtype(gobject.ext.types.string) == 0) {
                // No text. If the clipboard has an image and image paste is
                // enabled, paste the image (as a temp-file path) instead.
                const image_enabled = if (self.private().core_surface) |surface|
                    surface.config.clipboard_image_paste
                else
                    false;
                if (image_enabled and formats.containMimeType("image/png") != 0) {
                    return requestImage(self, clipboard_type);
                }

                log.debug("clipboard has no text format, not starting paste request", .{});
                return false;
            }
        }
```

- [x] **Step 2: Full build + install**

Run:
```bash
mise run build
mise run install
```
Expected: builds and installs.

- [ ] **Step 3: Manual verification — normal paste key**

Copy a screenshot (image only). In Ghostty at a shell prompt press the normal paste binding (`Ctrl+Shift+V`).
Expected: the `/tmp/ghostty-paste-*.png` path is pasted (same as the dedicated action).

- [ ] **Step 4: Manual verification — text paste unchanged**

Copy plain text, press `Ctrl+Shift+V`.
Expected: the text pastes exactly as before (no temp file created).

- [ ] **Step 5: Manual verification — multi-format prefers text**

Copy content that provides both image and text (e.g. a spreadsheet cell), press `Ctrl+Shift+V`.
Expected: text is pasted (not the image); the `paste_image` action still forces the image.

- [x] **Step 6: Commit**

```bash
zig fmt .
git add src/apprt/gtk/class/surface.zig
git commit -m "feat(gtk): auto-detect clipboard image on normal paste

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Future work (out of scope for this plan)

- **macOS implementation:** replace the `embedded.zig` `clipboardRequestImage` stub with a real NSPasteboard read (Swift side in `macos/`) that encodes PNG and calls back into `completeClipboardPasteImage` via the embedded C API. The core method and config are already cross-platform.
- **Stale-file pruning:** best-effort deletion of `ghostty-paste-*` files older than 24h in the target directory (the `prefix` constant is already exported for this).
- **Non-PNG clipboard sources:** GTK `saveToPngBytes` already re-encodes any texture to PNG; if a source provides only `image/tiff` etc. without a `GdkTexture`, revisit `requestImage`'s format check.
- **Remote/SSH:** the temp file is written locally; a remote shell won't see it.

## Self-Review Notes

- Spec coverage: action + auto-detect (Tasks 3, 6), path delivery via bracketed paste (Task 3 reuses `completeClipboardPaste`), cross-platform core + GTK read (Tasks 2–5), config incl. directory + max-size (Task 1), multi-format = text default (Task 6 Step 5). ✓
- Type consistency: `completeClipboardPasteImage(png: []const u8)`, `clipboardRequestImage(clipboard_type) !bool`, `Clipboard.requestImage`, and `apprt.clipboard_image.write(...)` names are used identically across tasks. ✓
- No placeholders: all steps contain concrete code and exact commands. ✓
