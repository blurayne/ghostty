# wait-after-failed-command Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a command running in a split exits with a non-zero status, keep the split open showing the exit status instead of closing it and taking the error output with it.

**Architecture:** Almost all the machinery exists. `Surface.childExited()` already sets a red "Command Failed" banner and already knows how to write a detail block into the terminal — but only for commands that fail within `abnormal-command-exit-runtime` (250 ms). A slow failure falls through to an unconditional `self.close()`. We add a config toggle, teach core `Surface` to ask the apprt whether it is in a split (the same pull pattern it already uses for `getContentScale()` / `getSize()` / `getTitle()`), and add one branch before that `close()`.

**Tech Stack:** Zig 0.16.0, GTK4 + libadwaita (GObject classes under `src/apprt/gtk/class/`), `zig build test`.

**Spec:** `docs/superpowers/specs/2026-09-08-wait-after-failed-command-design.md`

## Global Constraints

- **Splits only.** A lone window or tab still closes on non-zero exit. The gate is `rt_surface.isSplit()`.
- **Default on.** `wait-after-failed-command` defaults to `true`.
- **GTK only.** `embedded.isSplit()` returns `false`, so macOS behaviour is unchanged. This is deliberate — `info.exit_code` is unreliable on Darwin because of the `login` wrapper (see the existing comment at `src/Surface.zig:1288`).
- **No behaviour change on the existing fast-failure path.** Tasks 1–3 are all no-ops at runtime; only Task 4 changes what the user sees.
- **Exact copy strings**, used verbatim:
  - launch failure heading: `Ghostty failed to launch the requested command:`
  - non-zero exit heading: `Command exited with a non-zero status:`
  - launch failure hint: `Press any key to close the window.`
  - non-zero exit hint: `Press any key to close the split.`
- **Config docs comment ends with** `Available since: 1.4.0` (repo is `1.3.2-dev`; precedent at `src/config/Config.zig:3876`).
- **`DerivedConfig` fields are alphabetically ordered.** `wait_after_failed_command` goes immediately after `wait_after_command`, in both the struct and the initializer.

### Running tests — read this first

`mise run zig-test` and `mise run shell` **do not work on this machine.** Two independent reasons:

1. Rootless Docker is broken (`failed to start shim: ... unsupported protocol: Yunix`), so `docker compose run` cannot start a container.
2. The builder image has no GTK/GIO headers on the default include path — they live inside the `org.gnome.Sdk//50` flatpak runtime baked into the image. A bare `zig build` fails with `'gtk/gtk.h' not found`.

Use podman, and run zig *inside* the SDK sandbox. First, create the helper once:

```bash
cat > /tmp/ghostty-zigrun.sh <<'SCRIPT'
#!/bin/bash
set -e
[ -d /opt/zig ] || { mkdir -p /opt && cp -a /usr/local/zig /opt/zig; }
mkdir -p /root/.cache/zig
exec flatpak run --devel \
  --share=network \
  --filesystem=/workspace \
  --filesystem=/opt/zig \
  --filesystem=/root/.cache/zig \
  --env=PATH=/opt/zig:/app/bin:/usr/bin \
  --env=ZIG_GLOBAL_CACHE_DIR=/root/.cache/zig \
  --command=bash org.gnome.Sdk//50 -c "cd /workspace && zig $*"
SCRIPT
chmod +x /tmp/ghostty-zigrun.sh
```

If the builder image does not exist yet: `podman build -t ghostty-flatpak-builder:latest -f Dockerfile .`

Throughout this plan, **`ZT <args>`** is shorthand for:

```bash
podman run --rm --privileged \
  -v "$PWD":/workspace:z \
  -v /tmp/ghostty-zigrun.sh:/usr/local/bin/zigrun:ro \
  -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'zigrun <args>'
```

`-fno-sys=gtk4-layer-shell` is required on every build: `gtk4-layer-shell` is built by the flatpak manifest as a module and is not in the SDK, so it must be built from source. `--share=network` in the helper is what lets that fetch succeed.

**Known pre-existing failure:** `os.passwd.test_0` fails in this harness at unmodified `HEAD`. The test binary itself runs inside a flatpak sandbox, so `isFlatpak()` is true and `passwd.get()` tries to spawn a host command against a service that isn't there. Ignore it. Do not "fix" it. It only appears when a filter pulls it in.

**Do not run `zig build` for the `ghostty` exe in Debug.** It fails at `HEAD` with `src/tripwire.zig:160: error: function 'font.SharedGrid.renderGlyph' uses its own inferred error set here` — unrelated to this work, fails identically without `-Dflatpak`. Use `-Doptimize=ReleaseFast` when a full exe build is needed (Task 4).

## File Structure

| File | Responsibility | Task |
|---|---|---|
| `src/Surface.zig` | `ExitReason` enum owning the two copy variants; `DerivedConfig` field; the branch that decides not to close | 1, 3, 4 |
| `src/apprt/gtk/class/surface.zig` | `getIsSplit()` over the existing `is_split` private field | 2 |
| `src/apprt/gtk/Surface.zig` | `isSplit()` on the thin apprt wrapper | 2 |
| `src/apprt/embedded.zig` | `isSplit()` returning `false` | 2 |
| `src/config/Config.zig` | The `wait-after-failed-command` option and its docs | 3 |

Tasks are ordered so each one compiles and is reviewable alone. 1–3 change no behaviour; 4 is the switch.

---

### Task 1: `ExitReason` — correct copy for each failure mode

The detail block currently hardcodes *"Ghostty failed to launch the requested command:"*. That is accurate for a command that died in 40 ms and wrong for one that ran four seconds and then failed. Extract the copy into an enum so the two cases can differ, and so the strings are unit-testable without constructing a `Surface`.

**Files:**
- Modify: `src/Surface.zig` — add `ExitReason` near line 290; change `childExitedAbnormally()` at 1362; update its call site at 1309; add tests at end of file
- Test: `src/Surface.zig` (tests live at the bottom of the file, next to the existing `test "queueIo frees allocated writes in readonly mode"`)

**Interfaces:**
- Consumes: nothing
- Produces: `const ExitReason = enum { launch_failure, nonzero_exit }` with methods `heading() []const u8` and `dismissHint() []const u8`; `childExitedAbnormally(self: *Surface, info: apprt.surface.Message.ChildExited, reason: ExitReason) !void`

- [ ] **Step 1: Write the failing tests**

Append to the very end of `src/Surface.zig`, after the existing `test "queueIo frees allocated writes in readonly mode"` block:

```zig
test "ExitReason: heading distinguishes launch failure from non-zero exit" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "Ghostty failed to launch the requested command:",
        ExitReason.launch_failure.heading(),
    );
    try testing.expectEqualStrings(
        "Command exited with a non-zero status:",
        ExitReason.nonzero_exit.heading(),
    );
}

test "ExitReason: dismiss hint names the thing that will close" {
    const testing = std.testing;

    try testing.expectEqualStrings(
        "Press any key to close the window.",
        ExitReason.launch_failure.dismissHint(),
    );
    try testing.expectEqualStrings(
        "Press any key to close the split.",
        ExitReason.nonzero_exit.dismissHint(),
    );
}
```

- [ ] **Step 2: Run the tests to verify they fail**

```bash
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=ExitReason
```

Expected: compile error, `use of undeclared identifier 'ExitReason'`.

- [ ] **Step 3: Add the enum**

In `src/Surface.zig`, insert after the closing `};` of the `Keyboard` struct (line 290) and before the `/// The configuration that a surface has` comment on `DerivedConfig` (line 292):

```zig
/// Why a child process exit is being reported to the user. This selects the
/// wording of the message written into the terminal — the two cases look
/// nothing alike to a user and must not share copy.
const ExitReason = enum {
    /// The command exited so quickly we assume it never really started —
    /// a bad binary path, a missing interpreter, an immediate crash.
    launch_failure,

    /// The command ran, then exited with a non-zero status. It launched
    /// fine; it just failed.
    nonzero_exit,

    /// Headline written above the command in the detail block.
    fn heading(self: ExitReason) []const u8 {
        return switch (self) {
            .launch_failure => "Ghostty failed to launch the requested command:",
            .nonzero_exit => "Command exited with a non-zero status:",
        };
    }

    /// Closing hint written below the exit code. Only a split is kept open
    /// for `.nonzero_exit`, so that case names the split rather than the
    /// window.
    fn dismissHint(self: ExitReason) []const u8 {
        return switch (self) {
            .launch_failure => "Press any key to close the window.",
            .nonzero_exit => "Press any key to close the split.",
        };
    }
};
```

- [ ] **Step 4: Run the tests to verify they pass**

```bash
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=ExitReason
```

Expected: PASS. The summary line reports 0 failures (`os.passwd.test_0` is not matched by this filter).

- [ ] **Step 5: Thread the reason through `childExitedAbnormally`**

Change the signature at `src/Surface.zig:1362`:

```zig
fn childExitedAbnormally(
    self: *Surface,
    info: apprt.surface.Message.ChildExited,
    reason: ExitReason,
) !void {
```

Replace the hardcoded heading at line 1404. Before:

```zig
    try t.printString("Ghostty failed to launch the requested command:");
```

After:

```zig
    try t.printString(reason.heading());
```

Replace the hardcoded hint at line 1436. Before:

```zig
    try t.printString("Press any key to close the window.");
```

After:

```zig
    try t.printString(reason.dismissHint());
```

Update the only existing call site, at `src/Surface.zig:1309`. Before:

```zig
        self.childExitedAbnormally(info) catch |err| {
```

After:

```zig
        self.childExitedAbnormally(info, .launch_failure) catch |err| {
```

Passing `.launch_failure` here reproduces today's output byte for byte.

- [ ] **Step 6: Verify the whole test suite still compiles and passes**

```bash
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=Surface
```

Expected: PASS, 0 failures.

- [ ] **Step 7: Check formatting**

```bash
ZT fmt --check src/Surface.zig
```

Expected: no output, exit 0.

- [ ] **Step 8: Commit**

```bash
git add src/Surface.zig
git commit -m "surface: split child-exit copy into an ExitReason enum

The detail block hardcoded 'Ghostty failed to launch the requested
command:', which is accurate for a command that died in 40ms and wrong
for one that ran four seconds and then failed. No behaviour change --
the sole call site passes .launch_failure and produces identical output."
```

---

### Task 2: Let core ask whether a surface is in a split

Core `Surface` has no concept of splits; the apprt does. The GTK surface already carries an `is_split` private field, bound from the split tree's `is-split` property and re-bound whenever the tree changes (`src/apprt/gtk/class/split_tree.zig:561`). Expose it through the same pull path core already uses for `getTitle()` and `getContentScale()`.

**Files:**
- Modify: `src/apprt/gtk/class/surface.zig` — add `getIsSplit()` after `getTitle()` at line 2191-2193
- Modify: `src/apprt/gtk/Surface.zig` — add `isSplit()` after `getTitle()` at line 44-46
- Modify: `src/apprt/embedded.zig` — add `isSplit()` after `getTitle()` at line 678-680

**Interfaces:**
- Consumes: nothing from Task 1
- Produces: `rt_surface.isSplit() bool`, callable from core `Surface`. GTK returns the live split state; embedded returns `false`.

There is no unit test here. Both implementations are one-line field reads, and exercising them requires a live GObject surface inside a running GTK application — a test that would assert nothing the compiler doesn't already. Verification is that it compiles and that Task 4's manual checks observe the right behaviour.

- [ ] **Step 1: Add the GObject accessor**

`src/apprt/gtk/class/surface.zig`, immediately after `getTitle()` (which ends at line 2193):

```zig
    /// Whether this surface is currently one pane of a split. Mirrors the
    /// `is-split` property, which is bound from the owning split tree.
    pub fn getIsSplit(self: *Self) bool {
        return self.private().is_split;
    }
```

- [ ] **Step 2: Add the apprt wrapper method**

`src/apprt/gtk/Surface.zig`, immediately after `getTitle()` (line 44-46):

```zig
pub fn isSplit(self: *Self) bool {
    return self.surface.getIsSplit();
}
```

- [ ] **Step 3: Add the embedded stub**

`src/apprt/embedded.zig`, immediately after `getTitle()` (line 678-680):

```zig
    /// macOS manages splits on the Swift side and libghostty is not told
    /// about them, so we always report false. The practical effect is that
    /// `wait-after-failed-command` is a no-op on macOS. See the spec's
    /// follow-ups section.
    pub fn isSplit(self: *Surface) bool {
        _ = self;
        return false;
    }
```

- [ ] **Step 4: Verify it compiles**

```bash
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=ExitReason
```

Expected: PASS. (This compiles the GTK apprt as part of the test binary; a signature mistake shows up here.)

- [ ] **Step 5: Check formatting**

```bash
ZT fmt --check src/apprt/gtk/class/surface.zig src/apprt/gtk/Surface.zig src/apprt/embedded.zig
```

Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/apprt/gtk/class/surface.zig src/apprt/gtk/Surface.zig src/apprt/embedded.zig
git commit -m "apprt: expose whether a surface is part of a split

Core Surface needs this to decide whether to keep a failing command's
pane open. GTK reads the existing is_split field, which the split tree
already keeps bound. Embedded returns false -- macOS splits live on the
Swift side and libghostty is not told about them."
```

---

### Task 3: The `wait-after-failed-command` option

**Files:**
- Modify: `src/config/Config.zig` — new option after `wait-after-command` (line 1420)
- Modify: `src/Surface.zig` — `DerivedConfig` field after line 330; initializer after line 418

**Interfaces:**
- Consumes: nothing from Tasks 1–2
- Produces: `self.config.wait_after_failed_command` (`bool`) readable from any `Surface` method

Nothing reads this field yet — that is Task 4. Adding it separately keeps the config surface reviewable on its own, and the field being unused is not an error in Zig for a struct field.

- [ ] **Step 1: Add the config option**

`src/config/Config.zig`. The existing block ends at line 1420 with `@"wait-after-command": bool = false,`. Insert immediately after it, before the `/// The number of milliseconds of runtime below which...` comment:

```zig
/// If true, keep a split open after the command running in it exits with a
/// non-zero exit code, instead of closing the split immediately. The split
/// shows the command, its runtime and its exit code, and stays until you
/// dismiss it with any keypress or the banner's close button.
///
/// This only applies to surfaces that are part of a split, because closing
/// a split destroys output you can still see the rest of. A lone window or
/// tab closes on exit as usual; use `wait-after-command` to keep those open
/// too.
///
/// This has no effect on macOS.
///
/// Available since: 1.4.0
@"wait-after-failed-command": bool = true,
```

- [ ] **Step 2: Add the derived field**

`src/Surface.zig`. In `DerivedConfig`, the fields are alphabetical; line 330 is `wait_after_command: bool,` and line 331 is `window_padding_top: u32,`. Insert between them:

```zig
    wait_after_failed_command: bool,
```

- [ ] **Step 3: Add the derived initializer**

`src/Surface.zig`. Line 418 is `.wait_after_command = config.@"wait-after-command",` and line 419 is `.window_padding_top = ...`. Insert between them:

```zig
            .wait_after_failed_command = config.@"wait-after-failed-command",
```

- [ ] **Step 4: Verify the config layer still passes**

```bash
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=Config
```

Expected: PASS, 0 failures. A missing `DerivedConfig` initializer would be a compile error here, not a test failure.

- [ ] **Step 5: Check formatting**

```bash
ZT fmt --check src/config/Config.zig src/Surface.zig
```

Expected: no output, exit 0.

- [ ] **Step 6: Commit**

```bash
git add src/config/Config.zig src/Surface.zig
git commit -m "config: add wait-after-failed-command

Defaults to true. Nothing reads it yet."
```

---

### Task 4: Keep the split open

The behaviour change. Everything before this was scaffolding.

**Files:**
- Modify: `src/Surface.zig` — `childExited()`, the tail at lines 1352-1358

**Interfaces:**
- Consumes: `ExitReason.nonzero_exit` and `childExitedAbnormally(info, reason)` from Task 1; `rt_surface.isSplit()` from Task 2; `self.config.wait_after_failed_command` from Task 3
- Produces: nothing further

- [ ] **Step 1: Add the branch**

`src/Surface.zig`, at the end of `childExited()`. Before (lines 1352-1359):

```zig
    // Waiting after command we stop here. The terminal is updated, our
    // state is updated, and now its up to the user to decide what to do.
    if (self.config.wait_after_command) return;

    // If we aren't waiting after the command, then we exit immediately
    // with no confirmation.
    self.close();
}
```

After:

```zig
    // Waiting after command we stop here. The terminal is updated, our
    // state is updated, and now its up to the user to decide what to do.
    if (self.config.wait_after_command) return;

    // A command that failed in a split keeps the split open so the user can
    // read what went wrong. Runtime is deliberately not consulted here: the
    // abnormal branch above is about a command that never got started, this
    // is about one that ran and then failed, and a build that fails after
    // four seconds is exactly the case worth keeping on screen.
    //
    // The banner was already set above via the show_child_exited action, so
    // we only need to add the detail block and skip the close.
    if (self.config.wait_after_failed_command and
        info.exit_code != 0 and
        self.rt_surface.isSplit())
    {
        self.childExitedAbnormally(info, .nonzero_exit) catch |err| {
            // A split held open with no message still beats one that
            // vanished, so we don't fall through to close() here.
            log.err("error writing failed command message err={}", .{err});
        };
        return;
    }

    // If we aren't waiting after the command, then we exit immediately
    // with no confirmation.
    self.close();
}
```

- [ ] **Step 2: Verify it compiles and the suite passes**

```bash
ZT build test -fno-sys=gtk4-layer-shell -Dtest-filter=Surface
```

Expected: PASS, 0 failures.

- [ ] **Step 3: Check formatting**

```bash
ZT fmt --check src/Surface.zig
```

Expected: no output, exit 0.

- [ ] **Step 4: Build the real binary**

```bash
ZT build -Dflatpak=true -Doptimize=ReleaseFast -fno-sys=gtk4-layer-shell -Demit-macos-app=false
```

Expected: exit 0. Do **not** use Debug — see Global Constraints.

- [ ] **Step 5: Commit**

```bash
git add src/Surface.zig
git commit -m "surface: keep a split open when its command fails

A command that fails fast already keeps its pane and shows a 'Command
Failed' banner. A command that runs for seconds and then fails set the
same banner and then hit an unconditional close(), destroying it in the
same breath -- and taking the error output with it.

Gated on wait-after-failed-command (default true) and on the surface
actually being a split, so a lone window still closes on shell exit."
```

- [ ] **Step 6: Build and install the flatpak for manual testing**

`mise run build` uses the broken Docker daemon. Use podman:

```bash
printf '%s' "$(git rev-parse --short HEAD)" > .git-sha
podman run --rm --privileged \
  -v "$PWD":/workspace:z \
  -v ghostty-flatpak-cache:/root/.local/share/flatpak \
  -w /workspace localhost/ghostty-flatpak-builder:latest \
  bash -lc 'export PATH=/root/.local/bin:$PATH; mise run _flatpak-build'
mise run backup-flatpak
mise run install
```

Then **fully quit and relaunch Ghostty** — flatpak leaves a running instance on its old files, so the new binary only applies to processes started after the install.

- [ ] **Step 7: Manual verification**

Work through every row. Each is a distinct branch of the new condition.

| # | Do this | Expect |
|---|---|---|
| 1 | Split a tab. In one pane: `sh -c 'echo boom; sleep 1; exit 1'` | Pane **stays open**. Red "Command Failed" banner. Detail block reads `Command exited with a non-zero status:`, `Exit Code: 1`, runtime ≈ 1000 ms, `Press any key to close the split.` |
| 2 | Same command in an **unsplit** window | Window **closes**, as before |
| 3 | In a split: `sh -c 'sleep 1; exit 0'` | Split **closes** — zero exit is unaffected |
| 4 | In a split: `sh -c 'exit 1'` (fast) | Unchanged from today; heading still reads `Ghostty failed to launch the requested command:` and hint still says `close the window.` |
| 5 | Set `wait-after-failed-command = false` in config, reload, redo row 1 | Split **closes** |
| 6 | Restore the default. Redo row 1, then press any key | Split closes |
| 7 | Redo row 1, then click the banner's **Close** button | Split closes |
| 8 | Set `wait-after-command = true`, run `sh -c 'sleep 1; exit 0'` in a split | Split stays open — the older option still wins for zero exits |

- [ ] **Step 8: Update the spec status**

In `docs/superpowers/specs/2026-09-08-wait-after-failed-command-design.md`, change the front-matter `status: draft` to `status: implemented`.

```bash
git add docs/superpowers/specs/2026-09-08-wait-after-failed-command-design.md
git commit -m "docs: mark wait-after-failed-command spec implemented"
```

---

## Notes for the reviewer

- **`log` needs no new import.** `src/Surface.zig:41` already declares `const log = std.log.scoped(.surface);` at file scope, which is what the `log.err` in Task 4 uses.
- **No new translatable strings.** The banner text is unchanged and already goes through `i18n._()`. The terminal detail block is not localized today and this change does not start localizing it.
- **The config editor UI picks the option up for free.** `src/config/metadata.zig` enumerates public config fields at comptime and maps `bool` to a toggle widget, with the doc comment as its description. Nothing to do.
- **Adwaita < 1.3** selects `SurfaceChildExitedNoop`, whose `setData()` emits `close-request` and closes the surface. On such a system the split closes regardless of this option. Acceptable — Adwaita 1.3 shipped in 2023 — and out of scope.
