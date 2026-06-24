# P11 Report: Terminal Mirroring (Sourced Pane)

## Status: DONE

## Commit SHA: 13f15c11f

## Test Summary
All 57 build steps succeeded; full zig test suite passed (exit code 0, `-Dapp-runtime=none`).  
3 new unit tests in `src/termio/pty_handle.zig` covering refcount, subscribe/unsubscribe, and final unref.

## Changes Delivered

### New file
- `src/termio/pty_handle.zig` — `PtyHandle` struct: refcounted, mutex-protected subscriber list, `broadcast()`, `writePty()`, `subscribe/unsubscribe`, 3 unit tests.

### Core termio
- `src/termio.zig` — exports `PtyHandle`
- `src/termio/backend.zig` — `Kind.mirror` + `MirrorBackend` struct; all `Backend`/`ThreadData` dispatch methods updated with `.mirror` cases; `MirrorBackend.threadEnter` sets `td.backend = .{ .mirror = {} }` so `ThreadData.deinit()` is safe
- `src/termio/Exec.zig` — `pty_handle: ?*PtyHandle = null` field; `threadEnter` creates PtyHandle after `subprocess.start()` and subscribes primary Termio; read thread now calls `handle.broadcast()` instead of direct `processOutput`; `threadExit` signature takes `io: *Termio` for unsubscribe; `deinit` calls `pty_handle.unref()`
- `src/termio/Termio.zig` — `threadExit` passes `self` to `backend.threadExit`; errdefer updated similarly
- `src/termio/Options.zig` — `mirror_handle: ?*termio.PtyHandle = null` field (unused for now, path goes via backend directly)

### Surface layer
- `src/Surface.zig` — `init` gains `mirror_pty_handle: ?*termio.PtyHandle` param; IO-init block branches on mirror vs. exec with proper errdefer; `getPtyHandle()` public accessor; `childExitedAbnormally` handles `.mirror` case
- `src/apprt/embedded.zig` — passes `null` for new param

### Crash reporting
- `src/crash/sentry.zig` — `ThreadState.surface` changed to `?*Surface` (the PTY read thread serves N subscribers, not one); surface metadata block guarded with `if (thr_state.surface) |surface|`

### GTK wiring
- `src/apprt/gtk/class/surface.zig` — `mirror_source_uuid: ?[16]u8` in Private; `initSurface` resolves PtyHandle via `findSurfaceByUuid` + `getPtyHandle` and passes it to `surface.init`; `setMirrorSource()` public method; `Surface.new()` accepts `mirror_source` override
- `src/apprt/gtk/class/window.zig` — `mirror_source: ?[16]u8` slot in Private; `setMirrorSource()`/`getMirrorSource()` accessors
- `src/apprt/gtk/class/split_header.zig` — `gio`/`glib` imports; `initActionMap()` creates `"split-header"` action group with `copy-as-source` and `attach-sourced-pane` actions
- `src/apprt/gtk/class/split_tree.zig` — `newSplitMirrored(source_uuid)` creates a mirrored surface and splits right at 50%
- `src/apprt/gtk/ui/1.5/split-header.blp` — two new context menu items ("Copy as Source", "Attach Sourced Pane")

## Fix Round 1
- Fixed errdefer scope in Surface.zig (exec + mirror both now cover Termio.init failure)
- Fixed PtyHandle ref leak in GTK surface.zig (errdefer unref after ref)
- Fixed MirrorBackend.getProcessInfo signature to be generic
- Removed dead mirror_handle from Options.zig
- Added sourced pane doc comment to Config.zig
- Added meaningful assertions to two PtyHandle tests
- Tests: ZIG_ARGS="-Dapp-runtime=none" mise run zig-test → exit 0 (all passed)

## Concerns

1. **`Exec.childExitedAbnormally`** — `backend.zig` calls `exec.childExitedAbnormally()` but no such function exists in `Exec.zig`. This was a pre-existing condition in the branch (existed before P11) and does not fail to compile because the function appears to be unreachable in the current call graph. This is not a P11 regression.

2. **PtyHandle timing for `getPtyHandle()`** — For exec surfaces, `pty_handle` is only populated after `Exec.threadEnter()` runs (i.e., after the IO thread starts). The `mirror_source_uuid` path in `initSurface` is called during surface realization (GTK `realize` signal), which happens after the source surface's IO thread should already be running. However, if `findSurfaceByUuid` finds a surface whose IO thread has not yet entered `threadEnter`, `getPtyHandle()` returns `null` and the mirror falls back to a regular (non-mirrored) exec surface silently. A future improvement could defer mirror attachment or emit an error.

3. **Broadcast skips >8 subscribers** — The `broadcast()` uses a stack-local array of 8 pointers. If more than 8 surfaces mirror the same PTY, extras are skipped with a warning. This is documented in the code and matches the spec note.

4. **MirrorBackend does not set a PTY for the ThreadData backend** — For the mirror path `td.backend = .{ .mirror = {} }` is set in `MirrorBackend.threadEnter`. The `Exec`-specific assertion `assert(td.backend == .exec)` in `Exec.threadExit` is never hit for mirror surfaces since `Backend.threadExit` dispatches to `MirrorBackend.threadExit` directly.
