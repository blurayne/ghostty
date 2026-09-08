const std = @import("std");
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const posix = std.posix;
const build_config = @import("../build_config.zig");
const global = @import("../global.zig");
const xev = global.xev;

const log = std.log.scoped(.flatpak);

/// Returns true if we're running in a Flatpak environment.
pub fn isFlatpak() bool {
    // If we're not on Linux then we'll make this comptime false.
    if (comptime builtin.os.tag != .linux) return false;
    return if (std.Io.Dir.accessAbsolute(global.io(), "/.flatpak-info", .{}))
        true
    else |_|
        false;
}

/// A struct to help execute commands on the host via the
/// org.freedesktop.Flatpak.Development DBus module. This uses GIO/GLib
/// under the hood.
///
/// This always spawns its own thread and maintains its own GLib event loop.
/// This makes it easy for the command to behave synchronously similar to
/// std.process.Child.
///
/// There are lots of chances for low-hanging improvements here (automatic
/// pipes, /dev/null, etc.) but this was purpose built for my needs so
/// it doesn't have all of those.
///
/// Requires GIO, GLib to be available and linked.
pub const FlatpakHostCommand = struct {
    const fd_t = posix.fd_t;
    const EnvMap = std.process.Environ.Map;
    const gio_c = @import("gio_c");
    /// Flags for HostCommand method
    ///
    /// Ref: https://docs.flatpak.org/en/latest/libflatpak-api-reference.html#gdbus-method-org-freedesktop-Flatpak-Development.HostCommand
    const Flags = packed struct(c_uint) {
        /// Clear the environment
        clear_env: bool = false,
        /// Kill the sandbox when the caller disappears from the session bus
        watch_bus: bool = false,
        _reserved: std.meta.Int(.unsigned, @bitSizeOf(c_uint) - 2) = 0,
    };

    /// Argv are the arguments to call on the host with argv[0] being
    /// the command to execute.
    argv: []const []const u8,

    /// The cwd for the new process. If this is not set then it will use
    /// the current cwd of the calling process.
    cwd: ?[:0]const u8 = null,

    /// Environment variables for the child process. If this is null, this
    /// does not send any environment variables.
    env: ?*const EnvMap = null,

    /// File descriptors to send to the child process. It is up to the
    /// caller to create the file descriptors and set them up.
    stdin: fd_t,
    stdout: fd_t,
    stderr: fd_t,

    /// State of the process. This is updated by the dedicated thread it
    /// runs in and is protected by the given lock and condition variable.
    state: State = .{ .init = {} },
    state_mutex: std.Io.Mutex = .init,
    state_cv: std.Io.Condition = .init,

    /// Exit status we synthesize when the Flatpak session helper
    /// (`org.freedesktop.Flatpak`) disappears from the bus while our command
    /// is still running. The helper is the parent of every host command, so
    /// when it is torn down (e.g. systemd's default `OOMPolicy=stop` on
    /// `flatpak-session-helper.service`) its children are SIGKILLed and no
    /// `HostCommandExited` signal is ever emitted. 137 is `128 + SIGKILL`,
    /// the standard shell convention for a signal-terminated process, so this
    /// is a truthful status rather than a sentinel: the child really was
    /// killed. The `warn` log emitted alongside it is what distinguishes this
    /// from a child that genuinely exited 137.
    pub const host_died_status: u8 = 137;

    /// Payload of the `.started` state. Named (rather than anonymous) so
    /// that `transitionExited` can hand it back by value to whichever path
    /// won the race to end the command.
    const Started = struct {
        pid: u32,
        loop_xev: ?*xev.Loop,
        completion: ?*Completion,
        subscription: gio_c.guint,
        loop: *gio_c.GMainLoop,

        /// Watcher id from `g_bus_watch_name_on_connection`, or 0 if none
        /// is registered.
        name_watcher: gio_c.guint = 0,
    };

    /// State the process is in. This can't be inspected directly, you
    /// must use getters on the struct to get access.
    const State = union(enum) {
        /// Initial state
        init: void,

        /// Error starting. The error message is only available via logs.
        /// (This isn't a fundamental limitation, just didn't need the
        /// error message yet)
        err: void,

        /// Process started with the given pid on the host.
        started: Started,

        /// Process exited
        exited: struct {
            pid: u32,
            status: u8,
        },
    };

    pub const Completion = struct {
        callback: *const fn (ud: ?*anyopaque, l: *xev.Loop, c: *Completion, r: WaitError!u8) void = noopCallback,
        c_xev: xev.Completion = .{},
        userdata: ?*anyopaque = null,
        timer: ?xev.Timer = null,
        result: ?WaitError!u8 = null,
    };

    /// Errors that are possible from us.
    pub const Error = error{
        FlatpakMustBeStarted,
        FlatpakSpawnFail,
        FlatpakSetupFail,
        FlatpakRPCFail,
    };

    pub const WaitError = xev.Timer.RunError || Error;

    /// Spawn the command. This will start the host command. On return,
    /// the pid will be available. This must only be called with the
    /// state in "init".
    ///
    /// Precondition: The self pointer MUST be stable.
    pub fn spawn(self: *FlatpakHostCommand, alloc: Allocator) !u32 {
        const thread = try std.Thread.spawn(.{}, threadMain, .{ self, alloc });
        thread.setName(global.io(), "flatpak-host-command") catch {};
        // We don't track this thread, it will terminate on its own on command exit
        thread.detach();

        // Wait for the process to start or error.
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());
        while (self.state == .init) self.state_cv.waitUncancelable(global.io(), &self.state_mutex);

        return switch (self.state) {
            .init => unreachable,
            .err => Error.FlatpakSpawnFail,
            .started => |v| v.pid,
            .exited => |v| v.pid,
        };
    }

    /// Wait for the process to end and return the exit status. This
    /// can only be called ONCE. Once this returns, the state is reset.
    pub fn wait(self: *FlatpakHostCommand) !u8 {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());

        while (true) {
            switch (self.state) {
                .init => return Error.FlatpakMustBeStarted,
                .err => return Error.FlatpakSpawnFail,
                .started => {},
                .exited => |v| {
                    self.state = .{ .init = {} };
                    self.state_cv.broadcast(global.io());
                    return v.status;
                },
            }

            self.state_cv.waitUncancelable(global.io(), &self.state_mutex);
        }
    }

    /// Wait for the process to end asynchronously via libxev. This
    /// can only be called ONCE.
    pub fn waitXev(
        self: *FlatpakHostCommand,
        loop: *xev.Loop,
        completion: *Completion,
        comptime Userdata: type,
        userdata: ?*Userdata,
        comptime cb: *const fn (
            ud: ?*Userdata,
            l: *xev.Loop,
            c: *Completion,
            r: WaitError!u8,
        ) void,
    ) void {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());

        completion.* = .{
            .callback = (struct {
                fn callback(
                    ud_: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *Completion,
                    r: WaitError!u8,
                ) void {
                    const ud = @as(?*Userdata, if (Userdata == void) null else @ptrCast(@alignCast(ud_)));
                    @call(.always_inline, cb, .{ ud, l_inner, c_inner, r });
                }
            }).callback,
            .userdata = userdata,
            .timer = xev.Timer.init() catch unreachable, // not great, but xev timer can't fail atm
        };

        switch (self.state) {
            .init => completion.result = Error.FlatpakMustBeStarted,
            .err => completion.result = Error.FlatpakSpawnFail,
            .started => |*v| {
                v.loop_xev = loop;
                v.completion = completion;
                return;
            },
            .exited => |v| {
                completion.result = v.status;
            },
        }

        completion.timer.?.run(
            loop,
            &completion.c_xev,
            0,
            anyopaque,
            completion.userdata,
            (struct {
                fn callback(
                    ud: ?*anyopaque,
                    l_inner: *xev.Loop,
                    c_inner: *xev.Completion,
                    r: xev.Timer.RunError!void,
                ) xev.CallbackAction {
                    const c_outer: *Completion = @fieldParentPtr("c_xev", c_inner);
                    defer if (c_outer.timer) |*t| t.deinit();

                    const result = if (r) |_| c_outer.result.? else |err| err;
                    c_outer.callback(ud, l_inner, c_outer, result);
                    return .disarm;
                }
            }).callback,
        );
    }

    /// Send a signal to the started command. This does nothing if the
    /// command is not in the started state.
    pub fn signal(self: *FlatpakHostCommand, sig: u8, pg: bool) !void {
        const pid = pid: {
            self.state_mutex.lockUncancelable(global.io());
            defer self.state_mutex.unlock(global.io());
            switch (self.state) {
                .started => |v| break :pid v.pid,
                else => return,
            }
        };

        // Get our bus connection.
        var g_err: ?*gio_c.GError = null;
        defer if (g_err) |ptr| gio_c.g_error_free(ptr);
        const bus = gio_c.g_bus_get_sync(gio_c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("signal error getting bus: {s}", .{g_err.?.*.message});
            return Error.FlatpakSetupFail;
        };
        defer gio_c.g_object_unref(bus);

        const reply = gio_c.g_dbus_connection_call_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommandSignal",
            gio_c.g_variant_new(
                "(uub)",
                pid,
                sig,
                @as(c_int, @intCast(@intFromBool(pg))),
            ),
            gio_c.G_VARIANT_TYPE("()"),
            gio_c.G_DBUS_CALL_FLAGS_NONE,
            gio_c.G_MAXINT,
            null,
            &g_err,
        );
        if (g_err != null) {
            log.warn("signal send error: {s}", .{g_err.?.*.message});
            return;
        }
        defer gio_c.g_variant_unref(reply);
    }

    fn threadMain(self: *FlatpakHostCommand, alloc: Allocator) void {
        // Create a new thread-local context so that all our sources go
        // to this context and we can run our loop correctly.
        const ctx = gio_c.g_main_context_new();
        defer gio_c.g_main_context_unref(ctx);
        gio_c.g_main_context_push_thread_default(ctx);
        defer gio_c.g_main_context_pop_thread_default(ctx);

        // Get our loop for the current thread
        const loop = gio_c.g_main_loop_new(ctx, 1).?;
        defer gio_c.g_main_loop_unref(loop);

        // Get our bus connection. This has to remain active until we exit
        // the thread otherwise our signals won't be called.
        var g_err: ?*gio_c.GError = null;
        defer if (g_err) |ptr| gio_c.g_error_free(ptr);
        const bus = gio_c.g_bus_get_sync(gio_c.G_BUS_TYPE_SESSION, null, &g_err) orelse {
            log.warn("spawn error getting bus: {s}", .{g_err.?.*.message});
            self.updateState(.{ .err = {} });
            return;
        };
        defer gio_c.g_object_unref(bus);

        // Spawn the command first. This will setup all our IO.
        self.start(alloc, bus, loop) catch |err| {
            log.warn("error starting host command: {}", .{err});
            self.updateState(.{ .err = {} });
            return;
        };

        // Run the event loop. It quits in the exit callback.
        gio_c.g_main_loop_run(loop);
    }

    /// Start the command. This will start the host command and set the
    /// pid field on success. This will not wait for completion.
    ///
    /// Once this is called, the self pointer MUST remain stable. This
    /// requirement is due to using GLib under the covers with callbacks.
    fn start(
        self: *FlatpakHostCommand,
        alloc: Allocator,
        bus: *gio_c.GDBusConnection,
        loop: *gio_c.GMainLoop,
    ) !void {
        var err: ?*gio_c.GError = null;
        defer if (err) |ptr| gio_c.g_error_free(ptr);
        var arena_allocator = std.heap.ArenaAllocator.init(alloc);
        defer arena_allocator.deinit();
        const arena = arena_allocator.allocator();

        // Our list of file descriptors that we need to send to the process.
        const fd_list = gio_c.g_unix_fd_list_new();
        defer gio_c.g_object_unref(fd_list);
        if (gio_c.g_unix_fd_list_append(fd_list, self.stdin, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        if (gio_c.g_unix_fd_list_append(fd_list, self.stdout, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }
        if (gio_c.g_unix_fd_list_append(fd_list, self.stderr, &err) < 0) {
            log.warn("error adding fd: {s}", .{err.?.*.message});
            return Error.FlatpakSetupFail;
        }

        // Build our arguments for the file descriptors.
        const fd_builder = gio_c.g_variant_builder_new(gio_c.G_VARIANT_TYPE("a{uh}"));
        defer gio_c.g_variant_builder_unref(fd_builder);
        gio_c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 0), self.stdin);
        gio_c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 1), self.stdout);
        gio_c.g_variant_builder_add(fd_builder, "{uh}", @as(c_int, 2), self.stderr);

        // Build our env vars
        const env_builder = gio_c.g_variant_builder_new(gio_c.G_VARIANT_TYPE("a{ss}"));
        defer gio_c.g_variant_builder_unref(env_builder);
        if (self.env) |env| {
            var it = env.iterator();
            while (it.next()) |pair| {
                const key = try arena.dupeZ(u8, pair.key_ptr.*);
                const value = try arena.dupeZ(u8, pair.value_ptr.*);
                gio_c.g_variant_builder_add(env_builder, "{ss}", key.ptr, value.ptr);
            }
        }

        // Build our args
        const args = try arena.alloc(?[*:0]u8, self.argv.len + 1);
        for (0.., self.argv) |i, arg| {
            const argZ = try arena.dupeZ(u8, arg);
            args[i] = argZ.ptr;
        }
        args[args.len - 1] = null;

        // Get the cwd in case we don't have ours set. A small optimization
        // would be to do this only if we need it but this isn't a
        // common code path.
        const g_cwd = gio_c.g_get_current_dir();
        defer gio_c.g_free(g_cwd);

        // Terminate session if Ghostty drops off the bus (e.g. due to crashes)
        const flags: Flags = .{ .watch_bus = true };

        // The params for our RPC call
        const params = gio_c.g_variant_new(
            "(^ay^aay@a{uh}@a{ss}u)",
            @as(*const anyopaque, if (self.cwd) |*cwd| cwd.ptr else g_cwd),
            args.ptr,
            gio_c.g_variant_builder_end(fd_builder),
            gio_c.g_variant_builder_end(env_builder),
            @as(c_uint, @bitCast(flags)),
        );
        _ = gio_c.g_variant_ref_sink(params); // take ownership
        defer gio_c.g_variant_unref(params);

        // Subscribe to exit notifications
        const subscription_id = gio_c.g_dbus_connection_signal_subscribe(
            bus,
            "org.freedesktop.Flatpak",
            "org.freedesktop.Flatpak.Development",
            "HostCommandExited",
            "/org/freedesktop/Flatpak/Development",
            null,
            0,
            onExit,
            self,
            null,
        );
        errdefer gio_c.g_dbus_connection_signal_unsubscribe(bus, subscription_id);

        // Go!
        const reply = gio_c.g_dbus_connection_call_with_unix_fd_list_sync(
            bus,
            "org.freedesktop.Flatpak",
            "/org/freedesktop/Flatpak/Development",
            "org.freedesktop.Flatpak.Development",
            "HostCommand",
            params,
            gio_c.G_VARIANT_TYPE("(u)"),
            gio_c.G_DBUS_CALL_FLAGS_NONE,
            gio_c.G_MAXINT,
            fd_list,
            null,
            null,
            &err,
        ) orelse {
            log.warn("Flatpak.HostCommand failed: {s}", .{err.?.*.message});
            return Error.FlatpakRPCFail;
        };
        defer gio_c.g_variant_unref(reply);

        var pid: u32 = 0;
        gio_c.g_variant_get(reply, "(u)", &pid);

        // The helper only tells us about exits via HostCommandExited, which
        // it obviously can't send if it is killed itself. Watch its bus name
        // so we notice that case too. This is registered on the same
        // connection and from threadMain's thread-default GMainContext, so
        // onNameVanished is dispatched on the same thread as onExit and the
        // two can't interleave.
        //
        // We only get here after a successful HostCommand call on this name,
        // so it has an owner and the immediate-vanish case can't fire
        // spuriously. Even if it did, transitionExited would ignore it.
        const name_watcher = gio_c.g_bus_watch_name_on_connection(
            bus,
            "org.freedesktop.Flatpak",
            gio_c.G_BUS_NAME_WATCHER_FLAGS_NONE,
            null, // name_appeared: a restarted helper doesn't revive our child
            onNameVanished,
            self,
            null, // user_data free func
        );
        errdefer gio_c.g_bus_unwatch_name(name_watcher);

        log.debug("HostCommand started pid={} subscription={}", .{
            pid,
            subscription_id,
        });

        self.updateState(.{
            .started = .{
                .pid = pid,
                .subscription = subscription_id,
                .loop = loop,
                .completion = null,
                .loop_xev = null,
                .name_watcher = name_watcher,
            },
        });
    }

    /// Helper to update the state and notify waiters via the cv.
    fn updateState(self: *FlatpakHostCommand, state: State) void {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());
        defer self.state_cv.broadcast(global.io());
        self.state = state;
    }

    /// Move the command from `.started` to `.exited` with the given status.
    ///
    /// This is the single choke point for ending a command, shared by the
    /// `HostCommandExited` signal and by helper-death detection. It is
    /// idempotent: if we are not in `.started` (already exited, never
    /// started, or errored) it returns null and changes nothing, so a late
    /// or duplicate signal is a harmless no-op. When `expect_pid` is
    /// non-null it must match the running pid, which is how `onExit` filters
    /// out the exits of *other* host commands — `HostCommandExited` is
    /// broadcast for all of them.
    ///
    /// On success the previous `.started` payload is returned so the caller
    /// can run the GLib teardown via `finishExit`. Any pending async waiter's
    /// result is recorded here too, under the same lock, so the state and the
    /// completion never disagree.
    ///
    /// Blocking `wait()` callers unblock via the `state_cv` broadcast.
    fn transitionExited(
        self: *FlatpakHostCommand,
        status: u8,
        expect_pid: ?u32,
    ) ?Started {
        self.state_mutex.lockUncancelable(global.io());
        defer self.state_mutex.unlock(global.io());

        const started = switch (self.state) {
            .started => |v| v,
            else => return null,
        };
        if (expect_pid) |pid| if (started.pid != pid) return null;

        self.state = .{ .exited = .{
            .pid = started.pid,
            .status = status,
        } };
        if (started.completion) |completion| completion.result = status;
        self.state_cv.broadcast(global.io());

        return started;
    }

    /// GLib-side teardown for a command that has just left `.started`.
    /// Must only be called with a `Started` returned by `transitionExited`,
    /// which guarantees exactly one caller reaches here per command.
    fn finishExit(
        self: *FlatpakHostCommand,
        bus: *gio_c.GDBusConnection,
        started: Started,
    ) void {
        _ = self;

        // Notify the async waiter, if any. The result was already recorded
        // by transitionExited.
        if (started.completion) |completion| {
            completion.timer.?.run(
                started.loop_xev.?,
                &completion.c_xev,
                0,
                anyopaque,
                completion.userdata,
                (struct {
                    fn callback(
                        ud_inner: ?*anyopaque,
                        l_inner: *xev.Loop,
                        c_inner: *xev.Completion,
                        r: xev.Timer.RunError!void,
                    ) xev.CallbackAction {
                        const c_outer: *Completion = @fieldParentPtr("c_xev", c_inner);
                        defer if (c_outer.timer) |*t| t.deinit();

                        const result = if (r) |_| c_outer.result.? else |err| err;
                        c_outer.callback(ud_inner, l_inner, c_outer, result);
                        return .disarm;
                    }
                }).callback,
            );
        }

        // We're done now, so we can unsubscribe. Unwatching from inside the
        // vanished callback is supported by GLib.
        gio_c.g_dbus_connection_signal_unsubscribe(bus, started.subscription);
        if (started.name_watcher != 0) gio_c.g_bus_unwatch_name(started.name_watcher);

        // We are also done with our loop so we can exit.
        gio_c.g_main_loop_quit(started.loop);
    }

    fn onExit(
        bus: ?*gio_c.GDBusConnection,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        _: [*c]const u8,
        params: ?*gio_c.GVariant,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self = @as(*FlatpakHostCommand, @ptrCast(@alignCast(ud)));

        // HostCommandExited is broadcast for every host command, so parse
        // first and let transitionExited filter on the pid.
        var pid: u32 = 0;
        var exit_status_raw: u32 = 0;
        gio_c.g_variant_get(params.?, "(uu)", &pid, &exit_status_raw);
        const exit_status = posix.W.EXITSTATUS(exit_status_raw);

        const started = self.transitionExited(exit_status, pid) orelse return;
        log.debug("HostCommand exited pid={} status={}", .{ pid, exit_status });
        self.finishExit(bus.?, started);
    }

    /// `org.freedesktop.Flatpak` lost its bus owner: the session helper died
    /// and took every host command with it. No HostCommandExited is coming,
    /// so report the child as killed ourselves.
    fn onNameVanished(
        bus: ?*gio_c.GDBusConnection,
        _: [*c]const u8,
        ud: ?*anyopaque,
    ) callconv(.c) void {
        const self = @as(*FlatpakHostCommand, @ptrCast(@alignCast(ud)));

        // No expected pid: this kills whatever we were running.
        const started = self.transitionExited(host_died_status, null) orelse return;
        log.warn("host service vanished, reporting child as killed pid={} status={}", .{
            started.pid,
            host_died_status,
        });
        self.finishExit(bus.?, started);
    }

    fn noopCallback(_: ?*anyopaque, _: *xev.Loop, _: *Completion, _: WaitError!u8) void {}
};

// The tests below only compile under `-Dflatpak=true`, because
// FlatpakHostCommand imports `gio_c` which only exists in that build. They
// are reached via `_ = flatpak;` in os/main.zig, gated the same way.
//
// `loop` is left `undefined`: transitionExited never dereferences it, it
// only carries it across to finishExit, which is the part that needs a live
// bus and is therefore not unit-testable.
const testing = std.testing;

fn testCommand(state: FlatpakHostCommand.State) FlatpakHostCommand {
    return .{
        .argv = &.{},
        .stdin = 0,
        .stdout = 1,
        .stderr = 2,
        .state = state,
    };
}

fn testStarted(pid: u32) FlatpakHostCommand.State {
    return .{ .started = .{
        .pid = pid,
        .loop_xev = null,
        .completion = null,
        .subscription = 7,
        .loop = undefined,
    } };
}

test "flatpak: transitionExited from started sets exited status" {
    if (comptime !build_config.flatpak) return error.SkipZigTest;

    var cmd = testCommand(testStarted(1234));
    const started = cmd.transitionExited(3, 1234) orelse
        return error.TestExpectedTransition;

    try testing.expectEqual(@as(u32, 1234), started.pid);
    try testing.expectEqual(@as(FlatpakHostCommand.gio_c.guint, 7), started.subscription);
    try testing.expectEqual(@as(u32, 0), started.name_watcher);
    try testing.expect(cmd.state == .exited);
    try testing.expectEqual(@as(u32, 1234), cmd.state.exited.pid);
    try testing.expectEqual(@as(u8, 3), cmd.state.exited.status);
}

test "flatpak: transitionExited is a no-op when already exited" {
    if (comptime !build_config.flatpak) return error.SkipZigTest;

    var cmd = testCommand(.{ .exited = .{ .pid = 1234, .status = 0 } });
    try testing.expect(cmd.transitionExited(FlatpakHostCommand.host_died_status, null) == null);

    // The first exit wins; a late signal must not overwrite it.
    try testing.expect(cmd.state == .exited);
    try testing.expectEqual(@as(u8, 0), cmd.state.exited.status);
}

test "flatpak: transitionExited is a no-op from init" {
    if (comptime !build_config.flatpak) return error.SkipZigTest;

    var cmd = testCommand(.{ .init = {} });
    try testing.expect(cmd.transitionExited(FlatpakHostCommand.host_died_status, null) == null);
    try testing.expect(cmd.state == .init);
}

test "flatpak: transitionExited ignores pid mismatch" {
    if (comptime !build_config.flatpak) return error.SkipZigTest;

    // HostCommandExited fires for every host command, not just ours.
    var cmd = testCommand(testStarted(1234));
    try testing.expect(cmd.transitionExited(0, 5678) == null);
    try testing.expect(cmd.state == .started);
    try testing.expectEqual(@as(u32, 1234), cmd.state.started.pid);
}

test "flatpak: transitionExited records the result on a pending completion" {
    if (comptime !build_config.flatpak) return error.SkipZigTest;

    var completion: FlatpakHostCommand.Completion = .{};
    var cmd = testCommand(testStarted(1234));
    cmd.state.started.completion = &completion;

    _ = cmd.transitionExited(FlatpakHostCommand.host_died_status, null) orelse
        return error.TestExpectedTransition;
    try testing.expectEqual(
        @as(u8, FlatpakHostCommand.host_died_status),
        try completion.result.?,
    );
}
