---
date: 2026-09-08T12:42:26+00:00
git_commit: d15e1aabf6348681eb1af81af9ff2d8b1d4270c2
branch: main
topic: "Detect Flatpak host-command death when the session helper dies"
tags: [plan, flatpak, termio, dbus]
status: ready
---

# PLAN: Detect Flatpak host-command death when the session helper dies

`FlatpakHostCommand` learns that a host process died *only* via the `HostCommandExited` D-Bus signal emitted by `org.freedesktop.Flatpak` (i.e. `flatpak-session-helper`). When the helper itself is killed outright it never emits that signal, so the command's state stays `.started` forever: the terminal surface is never told its child is gone, the tab sits there accepting input that goes nowhere, and the dedicated GLib thread never unwinds.

This is not hypothetical. On 2026-09-08 a global OOM caused systemd to tear down `flatpak-session-helper.service` (default `OOMPolicy=stop`), SIGKILLing every host command Ghostty had running. All Ghostty tabs went silently dead while Ghostty itself stayed healthy. Full post-mortem: [`OOM.md`](../../../OOM.md).

Goal: make helper death a *detected, reported* condition on every path that waits for a host command.

## Acceptance Criteria

- When `org.freedesktop.Flatpak` loses its bus owner while a host command is in `.started`, the command transitions to `.exited` with status `137` instead of staying `.started` indefinitely.
- The async waiter (`termio/Exec.zig:185` via `waitXev`) fires its completion, so the surface receives `child_exited` and renders a normal exit notice rather than hanging.
- Both blocking waiters — the cwd probe (`termio/Exec.zig:995`) and `os/passwd.zig:72` — return instead of blocking forever on the condition variable.
- The GLib main loop is quit on this path, so the per-command `flatpak-host-command` thread exits and is not leaked.
- A late or duplicate `HostCommandExited` arriving after a vanish-triggered transition is a no-op and does not panic on the unchecked union access at `flatpak.zig:470`.
- Opening a new window/tab still works after the helper has died and restarted.
- No build-system change is required.

## Technical Key Decisions and Tradeoffs

1. **Report helper death as synthesized exit status `137`, not a new error variant.**
   - Why: `termio/Exec.zig:332` does `const exit_code = r catch unreachable;`. Delivering a `WaitError` down the existing completion path would panic in safe builds and be UB in `ReleaseFast`. `137` is `128 + SIGKILL`, the standard shell convention for a signal-terminated process, and is truthful — the child really was killed.
   - Impact: no signature change to `WaitError`, no consumer changes, no new panic sites. The surface shows "process exited with code 137".
   - Tradeoff: callers cannot distinguish "helper died" from "child genuinely exited 137". Accepted; the distinction is captured in the log line instead. A dedicated `error.FlatpakHostDied` remains a possible follow-up once the `catch unreachable` sites are hardened.

2. **Watch the bus name from inside `threadMain`'s thread-default context.**
   - Why: `threadMain` pushes its own `GMainContext` before calling `start()`, so a watcher registered there delivers its callback on the *same thread* as `onExit`. GLib dispatches one callback at a time per context, which eliminates the vanish-vs-exit race for free — no additional locking needed beyond the existing `state_mutex`.
   - Impact: the watcher is created in `start()` and its id stored in the `.started` payload so both teardown paths can unwatch it.

3. **Use `g_bus_watch_name_on_connection`, not a `NameOwnerChanged` subscription.**
   - Why: it is the purpose-built API, reuses the connection we already hold, and gives a direct `name_vanished` callback rather than requiring us to parse `NameOwnerChanged` arguments and filter for empty new-owner.
   - Impact: `gio_c` is translate-c over `#include <gio/gio.h>` (`src/build/SharedDeps.zig:676-679`), so `g_bus_watch_name_on_connection` and `g_bus_unwatch_name` are already exposed. **No build-system change.**

4. **Extract the `.started` → `.exited` transition into a pure, testable function.**
   - Why: the real path needs a live session bus and a killable helper, which is not unit-testable. The *state machine* — including the idempotency that prevents the panic — is pure and is where the subtle bugs live.
   - Impact: `onExit` and the new vanish handler both route through one function, which is also the fix for the unchecked `self.state.started` access at `flatpak.zig:470`.

5. **Fix all three consumers in one change rather than only the async path.**
   - Why: same root cause, three entry points. The blocking cwd probe runs during surface creation, so a partial fix would leave a dead helper able to hang *new window creation* — a worse symptom than the one being fixed.
   - Impact: no changes needed in `wait()` itself; it already loops on the condition variable and returns on `.exited`, so it unblocks for free once the transition happens and `updateState` broadcasts.

## Current State

```
Ghostty (Flatpak sandbox)
 └─ termio/Exec.zig → Subprocess.start()
      └─ FlatpakHostCommand.spawn()
           └─ threadMain()        [dedicated thread, own GMainContext + GMainLoop]
                ├─ g_bus_get_sync(SESSION)
                ├─ start()
                │    ├─ signal_subscribe("HostCommandExited") ──→ onExit
                │    └─ call_sync("HostCommand") → pid
                │         state = .started{pid, subscription, loop, …}
                └─ g_main_loop_run(loop)   ←── blocks until onExit quits it
```

`.started` has exactly one exit path (`src/os/flatpak.zig:457-518`):

```
helper ──HostCommandExited──→ onExit ├─ state = .exited{pid,status}
                                     ├─ fire xev completion → flatpakExit → surface
                                     ├─ signal_unsubscribe
                                     └─ g_main_loop_quit   ← thread returns
```

Kill the helper and none of that runs. Three consumers, two failure modes:

| Consumer | Call | Behaviour when the helper dies |
|---|---|---|
| `termio/Exec.zig:185` | `waitXev` (async) | completion never fires → tab hangs silently |
| `termio/Exec.zig:995` | `wait()` (blocking, cwd probe) | blocks forever → new window never opens |
| `os/passwd.zig:72` | `wait()` (blocking) | blocks forever |

Plus `g_main_loop_run` never returns, leaking one thread per hung terminal.

### Landmines in the existing code

- **`src/termio/Exec.zig:332`** — `const exit_code = r catch unreachable;` in `flatpakExit`. Any error delivered through the completion panics here.
- **`src/os/flatpak.zig:470`** — `break :state self.state.started;` is an *unchecked* union field access. `HostCommandExited` is broadcast for **every** host command (the subscription passes `null` for the arg filter), so `onExit` runs for other commands' exits too. Today the pid check at line 476 catches that, but only *after* the unchecked access. Once a second path can set `.exited`, a late signal reaches this line with the union in the wrong variant and panics.

## Desired End State

```
                    ┌─────────────── either path ───────────────┐
                    │                                            │
helper ──HostCommandExited──→ onExit                             │
                                  │                              │
org.freedesktop.Flatpak           │        name owner lost       │
   loses bus owner ───────────────┼──→ onNameVanished ───────────┤
                                  │                              │
                                  ▼                              ▼
                        transitionExited(status, expect_pid)  [idempotent]
                                  │
                          returns Started, or null if already left .started
                                  │
                                  ▼
                            finishExit(bus, started)
                              ├─ fire xev completion → surface "child exited"
                              ├─ g_dbus_connection_signal_unsubscribe
                              ├─ g_bus_unwatch_name
                              └─ g_main_loop_quit   ← thread unwinds
```

Blocking `wait()` callers unblock automatically: `transitionExited` sets `.exited` and broadcasts on `state_cv`, which is exactly what `wait()`'s loop (`flatpak.zig:147-160`) already waits for.

## Abstractions and Code Reuse

The existing `updateState` / `state_cv` machinery already does everything the blocking waiters need; the only reason they hang is that nothing ever calls it. The new code adds one detection source and funnels both sources through one transition.

- `src/os`
  - `flatpak.zig` — detection + idempotent transition
    - `Started` — **new**; extract the anonymous `.started` payload into a named struct so it can be returned by value, and add a `name_watcher: gio_c.guint` field
    - `host_died_status` — **new**; `pub const host_died_status: u8 = 137`
    - `transitionExited` — **new**; pure, lock-guarded, idempotent `.started` → `.exited`, takes an optional expected pid
    - `finishExit` — **new**; shared GLib teardown (completion, unsubscribe, unwatch, loop quit)
    - `onNameVanished` — **new**; `GBusNameVanishedCallback`, delegates to `transitionExited` + `finishExit`
    - `start` — register the name watcher, store its id in `Started`
    - `onExit` — rewritten to use `transitionExited` + `finishExit`; removes the unchecked union access
- `src/termio`
  - `Exec.zig` — **no change**. `flatpakExit` keeps working because it receives a `u8`, not an error.
- `src/os`
  - `passwd.zig` — **no change**. `wait()` unblocks via the existing broadcast.
- `OOM.md` (repo root) — update the closing "Note on the Ghostty source side" section to record that the gap is fixed and reference this plan.

## Logging & Observability

`onExit` already logs at debug. Helper death is an abnormal, user-visible event, so it warrants `warn`:

```
warn(flatpak): host service vanished, reporting child as killed pid=88220 status=137
```

Existing lines are kept unchanged:

```
debug(flatpak): HostCommand started pid=88220 subscription=7
debug(flatpak): HostCommand exited pid=88220 status=0
```

The `warn` line is what distinguishes "helper died" from a genuine `exit 137` in the log, which is the information the synthesized-status decision trades away at the API level.

## Implementation

### Phase 1: Idempotent exit transition

Dependencies: None.

Pure refactor plus hardening, with no behaviour change on the happy path. Delivers a standalone fix for the latent panic at `flatpak.zig:470` and establishes the seam the next phase plugs into. Fully unit-testable without a bus.

**Tasks**:
- [x] Extract the anonymous `.started` union payload in `State` into a named `Started` struct, adding `name_watcher: gio_c.guint = 0`.
- [x] Add `pub const host_died_status: u8 = 137;` with a comment explaining the `128 + SIGKILL` convention.
- [x] Add `transitionExited(self, status: u8, expect_pid: ?u32) ?Started` — takes `state_mutex` once, returns `null` if the state is not `.started` or if `expect_pid` is non-null and does not match, otherwise sets `.exited`, broadcasts `state_cv`, and returns the previous `Started` payload.
  ```zig
  fn transitionExited(self: *FlatpakHostCommand, status: u8, expect_pid: ?u32) ?Started {
      self.state_mutex.lockUncancelable(global.io());
      defer self.state_mutex.unlock(global.io());

      const started = switch (self.state) {
          .started => |v| v,
          else => return null,          // already exited, or never started
      };
      if (expect_pid) |pid| if (started.pid != pid) return null;

      self.state = .{ .exited = .{ .pid = started.pid, .status = status } };
      self.state_cv.broadcast(global.io());
      return started;
  }
  ```
- [x] Add `finishExit(self, bus, started: Started)` holding the GLib teardown currently inlined in `onExit`: fire the xev completion if present, `g_dbus_connection_signal_unsubscribe`, and `g_main_loop_quit`. Leave the `g_bus_unwatch_name` call out until Phase 2 adds the watcher.
- [x] Rewrite `onExit` to parse the pid/status first, then call `transitionExited(status, pid)` and return early on `null`, then call `finishExit`. This removes `break :state self.state.started;` entirely.
- [x] Add tests, gated on `build_config.flatpak`, using `undefined` for the `*GMainLoop` field since `transitionExited` never dereferences it.

**Automated Verification**:

All commands run inside the dev container (`mise run shell`) — never on the host. `-Dflatpak` defaults to `false`, so it must be passed explicitly or `flatpak.zig` is not analysed at all.

- [x] `zig build test -Dflatpak=true -Dtest-filter=flatpak` passes, covering:
  - [x] `flatpak: transitionExited from started sets exited status` — `.started` → `.exited` with the given status and preserved pid.
  - [x] `flatpak: transitionExited is a no-op when already exited` — returns `null`, leaves state untouched.
  - [x] `flatpak: transitionExited is a no-op from init` — returns `null`.
  - [x] `flatpak: transitionExited ignores pid mismatch` — returns `null` when `expect_pid` differs, leaving state `.started`.
- [x] `zig fmt --check src/os/flatpak.zig` is clean.
- [x] `zig build -Dflatpak=true` succeeds — in `ReleaseFast`. Debug fails on a pre-existing, unrelated error; see Implementation Notes.
- [x] `zig build` (without `-Dflatpak`) still succeeds — confirms the test gating did not break non-flatpak builds. Same Debug caveat.

### Phase 2: Bus-name-vanished detection

Dependencies: Phase 1.

Wires the actual detection source into the seam from Phase 1 and makes the user-visible behaviour correct.

**Tasks**:
- [x] In `start()`, after the `HostCommand` call returns a pid, register the watcher on the same connection and store the id in the `Started` payload passed to `updateState`:
  ```zig
  const name_watcher = gio_c.g_bus_watch_name_on_connection(
      bus,
      "org.freedesktop.Flatpak",
      gio_c.G_BUS_NAME_WATCHER_FLAGS_NONE,
      null,             // name_appeared: not needed
      onNameVanished,
      self,
      null,             // user_data free func
  );
  ```
- [x] Add the `onNameVanished` callback matching `GBusNameVanishedCallback` — `(connection, name, user_data)`:
  ```zig
  fn onNameVanished(
      bus: ?*gio_c.GDBusConnection,
      _: [*c]const u8,
      ud: ?*anyopaque,
  ) callconv(.c) void {
      const self: *FlatpakHostCommand = @ptrCast(@alignCast(ud));
      const started = self.transitionExited(host_died_status, null) orelse return;
      log.warn("host service vanished, reporting child as killed pid={} status={}", .{
          started.pid, host_died_status,
      });
      self.finishExit(bus.?, started);
  }
  ```
- [x] Add `g_bus_unwatch_name(started.name_watcher)` to `finishExit`, guarded on a non-zero id so it is safe on both teardown paths. Calling it from inside the vanished callback is supported by GLib.
- [x] Update the `OOM.md` "Note on the Ghostty source side" section to state the gap is closed and link this plan.

**Automated Verification**:
- [x] `zig build test -Dflatpak=true -Dtest-filter=flatpak` still passes (Phase 1 tests must be unaffected by the added `name_watcher` field).
- [x] `zig fmt --check src/os/flatpak.zig` is clean.
- [x] `zig build -Dflatpak=true` succeeds — in `ReleaseFast`. Debug fails on a pre-existing, unrelated error; see Implementation Notes.

**Manual Verification**:
- [ ] Build and install from the dev container: `rm -rf .flatpak-builder/build flatpak/builddir && mise run build && mise run install`.
- [ ] Open two Ghostty tabs, run `sleep 999` in each.
- [ ] `systemctl --user stop flatpak-session-helper.service`.
- [ ] **Both** tabs report the child exited (status 137) rather than hanging.
- [ ] `journalctl --user -n 20 | grep flatpak` shows the `host service vanished` warning, and no `signal send error: ... No such pid` spam.
- [ ] Opening a new tab/window afterwards still works — confirms the blocking cwd probe at `Exec.zig:995` no longer deadlocks.
- [ ] `ls /proc/$(pgrep -f '/app/bin/ghostty')/task | wc -l` does not grow across repeated kill/reopen cycles — confirms the loop-quit fix released the per-command threads.

## Risks and Open Considerations

- **Test compilation gating.** `flatpak.zig` imports `gio_c` inside the struct body, so it is only analysed when referenced. Tests force that analysis, meaning the new tests only compile under `-Dflatpak=true` (`src/build/Config.zig:191-193`, default `false`). Gate the test blocks behind `build_config.flatpak` so ordinary `zig build test` runs are unaffected. If that gating turns out not to work cleanly, fall back to testing `transitionExited` through a small state-only struct that does not touch `gio_c`. This is the single most likely place for the implementation to snag.
- **Spurious immediate vanish.** `g_bus_watch_name_on_connection` invokes `name_vanished` immediately if the name currently has no owner. The watcher is registered only *after* a successful `HostCommand` call on that same name, so an owner exists. `transitionExited` returning `null` outside `.started` makes a spurious early call harmless regardless.
- **Helper restart is not recovery.** `flatpak-session-helper` is D-Bus activated and will come back, firing `name_appeared`. That does not resurrect the dead children, which is why `name_appeared` is deliberately `null`. Existing commands stay `.exited`; new commands spawn against the new helper normally.
- **Does not prevent the OOM.** This change makes helper death *visible and clean*; it does not stop it happening. The `OOMPolicy=continue` drop-in described in `OOM.md` is the complementary mitigation, and is itself explicitly temporary.

## Implementation Notes

During implementation, document user feedback, problems, and decisions here.

### Deviations from the plan

- **`transitionExited` also records `completion.result`.** The plan gives `finishExit(self, bus, started)` no status parameter, so the pending async waiter's result has to be set somewhere else. It is set inside `transitionExited`, under the same `state_mutex` that sets `.exited` — the state and the completion are the same fact, so recording them together makes them impossible to disagree. `finishExit` then only *fires* the completion.
- **One extra test.** `flatpak: transitionExited records the result on a pending completion` covers the above. The plan's four tests are all present and pass.
- **Test gating lives in `src/os/main.zig`, not in the test bodies.** `if (comptime build_config.flatpak) _ = flatpak;` in the `test` block. A `comptime` guard inside each test body would not have worked: the body is still semantically analysed, so `gio_c` would still have to exist. The `return error.SkipZigTest` guards in the bodies are belt-and-braces. This was flagged in the plan as the most likely place to snag; it did not snag.

### Environment problems hit along the way (not code issues)

These cost most of the time and are worth recording for the next run:

1. **Rootless Docker on this host is broken.** `docker compose run` fails with `failed to start shim: ... unsupported protocol: Yunix` — the daemon is handing containerd a corrupted shim address (raw protobuf bytes in the address string). `mise run zig-test` / `mise run shell` therefore do not work at all right now. **Restarting `systemctl --user restart docker` is the likely fix**, but it would also stop the running `skill-matrix-postgres` and buildx containers, so it was left alone. Everything here ran under **podman** instead, which works fine.
2. **The builder image has no GTK/GIO headers on the default include path.** They live inside the `org.gnome.Sdk//50` flatpak runtime baked into the base image, so a bare `zig build` in the container fails with `'gtk/gtk.h' not found`. This affects `mise run zig-build` and `mise run zig-test` as written, independent of this change. Builds must run *inside* the SDK sandbox:

   ```bash
   podman build -t ghostty-flatpak-builder:latest -f Dockerfile .
   podman run --rm --privileged -v "$PWD":/workspace:z -w /workspace \
     ghostty-flatpak-builder:latest bash -lc '
       cp -a /usr/local/zig /opt/zig   # /usr is reserved by flatpak, cannot be shared in
       flatpak run --devel --share=network \
         --filesystem=/workspace --filesystem=/opt/zig --filesystem=/root/.cache/zig \
         --env=PATH=/opt/zig:/app/bin:/usr/bin \
         --env=ZIG_GLOBAL_CACHE_DIR=/root/.cache/zig \
         --command=bash org.gnome.Sdk//50 -c "cd /workspace && zig build test -Dflatpak=true -fno-sys=gtk4-layer-shell -Dtest-filter=flatpak"'
   ```

   `-fno-sys=gtk4-layer-shell` is required: `gtk4-layer-shell` is built by the flatpak manifest as a module and is not in the SDK, so it has to be built from source. `--share=network` is required for that fetch.
3. **`os.passwd.test_0` fails in this setup, and does so at unmodified `HEAD` too.** Verified with a detached worktree at `HEAD`. Cause: the test binary is itself running inside a flatpak sandbox, so `isFlatpak()` is true and `passwd.get()` tries to spawn a real host command against a `org.freedesktop.Flatpak` service that isn't there. Artifact of the harness, not a regression.
4. **`zig build -Dflatpak=true` fails in Debug at unmodified `HEAD`**: `src/tripwire.zig:160: error: function 'font.SharedGrid.renderGlyph' uses its own inferred error set here`. It fails identically *without* `-Dflatpak` — a configuration in which `flatpak.zig` is not analysed at all — so it is unrelated to this change. It is a Zig 0.16 fallout in this fork, worth its own fix. **`-Doptimize=ReleaseFast` builds clean**, which is what the flatpak bundle uses, and that build does link the new `start()` / `onNameVanished` / `finishExit` code.

### Evidence

- `zig build test -Dflatpak=true -fno-sys=gtk4-layer-shell -Dtest-filter=flatpak` → **80/81 pass**, the sole failure being the pre-existing `os.passwd.test_0` above.
- The new tests were confirmed to actually execute (not silently gated out) by temporarily inverting an assertion: the run then reported `'os.flatpak.test.flatpak: transitionExited from started sets exited status' failed`. The canary was reverted.
- `zig fmt --check src/os/flatpak.zig src/os/main.zig` → clean.
- `zig build -Dflatpak=true -Doptimize=ReleaseFast` → succeeds.

### Still outstanding

Manual verification (kill `flatpak-session-helper.service` with live tabs) has **not** been done — it needs a real install on the host, which is the user's call.

## References

- `OOM.md` — 2026-09-08 post-mortem: the incident this plan responds to
- `src/os/flatpak.zig:457-518` — `onExit`, the sole current exit path
- `src/os/flatpak.zig:143-161` — blocking `wait()`, unblocked for free by the transition
- `src/os/flatpak.zig:467-471` — the unchecked union access removed in Phase 1
- `src/termio/Exec.zig:181-195` — `waitXev` registration
- `src/termio/Exec.zig:326-334` — `flatpakExit` and the `catch unreachable` constraint
- `src/termio/Exec.zig:966-998` — the blocking cwd probe
- `src/os/passwd.zig:72` — the other blocking `wait()` caller
- `src/build/SharedDeps.zig:665-688` — `gio_c` translate-c setup confirming the GLib symbols are available
- [GLib: `g_bus_watch_name_on_connection`](https://docs.gtk.org/gio/func.bus_watch_name_on_connection.html)
- [Flatpak Development D-Bus API](https://docs.flatpak.org/en/latest/libflatpak-api-reference.html#gdbus-method-org-freedesktop-Flatpak-Development)
