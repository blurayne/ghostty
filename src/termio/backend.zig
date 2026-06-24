const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const renderer = @import("../renderer.zig");
const terminal = @import("../terminal/main.zig");
const termio = @import("../termio.zig");
const ProcessInfo = @import("../pty.zig").ProcessInfo;

// The preallocation size for the write request pool. This should be big
// enough to satisfy most write requests. It must be a power of 2.
const WRITE_REQ_PREALLOC = std.math.pow(usize, 2, 5);

/// The kinds of backends.
pub const Kind = enum { exec, mirror };

/// Configuration for the various backend types.
pub const Config = union(Kind) {
    /// Exec uses posix exec to run a command with a pty.
    exec: termio.Exec.Config,

    /// Mirror receives output from another surface's PTY handle.
    mirror: void,
};

/// A mirror backend that receives PTY output broadcast from a PtyHandle.
/// It does not own a subprocess — it subscribes to an existing PtyHandle
/// so the same PTY output is delivered to multiple Terminal instances.
pub const MirrorBackend = struct {
    pty_handle: *termio.PtyHandle,

    pub fn deinit(self: *MirrorBackend) void {
        self.pty_handle.unref();
    }

    pub fn initTerminal(_: *MirrorBackend, _: *terminal.Terminal) void {}

    pub fn threadEnter(
        self: *MirrorBackend,
        _: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        // Set the backend thread data to mirror (void) so that
        // ThreadData.deinit() knows the backend variant.
        td.backend = .{ .mirror = {} };
        try self.pty_handle.subscribe(io);
    }

    pub fn threadExit(self: *MirrorBackend, io: *termio.Termio) void {
        self.pty_handle.unsubscribe(io);
    }

    pub fn focusGained(_: *MirrorBackend, _: *termio.Termio.ThreadData, _: bool) !void {}

    pub fn resize(_: *MirrorBackend, _: renderer.GridSize, _: renderer.ScreenSize) !void {
        // Mirror surfaces don't resize the PTY (primary controls PTY size).
    }

    pub fn queueWrite(
        self: *MirrorBackend,
        _: Allocator,
        _: *termio.Termio.ThreadData,
        data: []const u8,
        _: bool,
    ) !void {
        self.pty_handle.writePty(data);
    }

    pub fn childExitedAbnormally(
        _: *MirrorBackend,
        _: Allocator,
        _: *terminal.Terminal,
        _: u32,
        _: u64,
    ) !void {}

    pub fn getProcessInfo(_: *MirrorBackend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return null;
    }
};

/// Backend implementations. A backend is responsible for owning the pty
/// behavior and providing read/write capabilities.
pub const Backend = union(Kind) {
    exec: termio.Exec,
    mirror: MirrorBackend,

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(),
            .mirror => |*m| m.deinit(),
        }
    }

    pub fn initTerminal(self: *Backend, t: *terminal.Terminal) void {
        switch (self.*) {
            .exec => |*exec| exec.initTerminal(t),
            .mirror => |*m| m.initTerminal(t),
        }
    }

    pub fn threadEnter(
        self: *Backend,
        alloc: Allocator,
        io: *termio.Termio,
        td: *termio.Termio.ThreadData,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.threadEnter(alloc, io, td),
            .mirror => |*m| try m.threadEnter(alloc, io, td),
        }
    }

    pub fn threadExit(self: *Backend, io: *termio.Termio, td: *termio.Termio.ThreadData) void {
        switch (self.*) {
            .exec => |*exec| exec.threadExit(io, td),
            .mirror => |*m| m.threadExit(io),
        }
    }

    pub fn focusGained(
        self: *Backend,
        td: *termio.Termio.ThreadData,
        focused: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.focusGained(td, focused),
            .mirror => |*m| try m.focusGained(td, focused),
        }
    }

    pub fn resize(
        self: *Backend,
        grid_size: renderer.GridSize,
        screen_size: renderer.ScreenSize,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.resize(grid_size, screen_size),
            .mirror => |*m| try m.resize(grid_size, screen_size),
        }
    }

    pub fn queueWrite(
        self: *Backend,
        alloc: Allocator,
        td: *termio.Termio.ThreadData,
        data: []const u8,
        linefeed: bool,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.queueWrite(alloc, td, data, linefeed),
            .mirror => |*m| try m.queueWrite(alloc, td, data, linefeed),
        }
    }

    pub fn childExitedAbnormally(
        self: *Backend,
        gpa: Allocator,
        t: *terminal.Terminal,
        exit_code: u32,
        runtime_ms: u64,
    ) !void {
        switch (self.*) {
            .exec => |*exec| try exec.childExitedAbnormally(
                gpa,
                t,
                exit_code,
                runtime_ms,
            ),
            .mirror => |*m| try m.childExitedAbnormally(gpa, t, exit_code, runtime_ms),
        }
    }

    /// Get information about the process(es) attached to the backend. Returns
    /// `null` if there was an error getting the information or the information
    /// is not available on a particular platform.
    pub fn getProcessInfo(self: *Backend, comptime info: ProcessInfo) ?ProcessInfo.Type(info) {
        return switch (self.*) {
            .exec => |*exec| exec.getProcessInfo(info),
            .mirror => null,
        };
    }
};

/// Termio thread data. See termio.ThreadData for docs.
pub const ThreadData = union(Kind) {
    exec: termio.Exec.ThreadData,
    mirror: void,

    pub fn deinit(self: *ThreadData, alloc: Allocator) void {
        switch (self.*) {
            .exec => |*exec| exec.deinit(alloc),
            .mirror => {},
        }
    }

    pub fn changeConfig(self: *ThreadData, config: *termio.DerivedConfig) void {
        _ = self;
        _ = config;
    }
};
