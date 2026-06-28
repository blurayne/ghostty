const std = @import("std");
const build_options = @import("terminal_options");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const terminal = @import("main.zig");
const DCS = terminal.DCS;

const log = std.log.scoped(.terminal_dcs);

/// Parameters extracted from the DCS `q` (sixel) header.
pub const SixelParams = struct {
    /// P2 / Pb — background select: 0=default bg (transparent), 1=black.
    ps: u16 = 0,
    /// P3 / Pc — colour register count (0 = use default 256).  Stored for
    /// completeness; the decoder always allocates 256 registers.
    pc: u16 = 0,
};

/// DCS command handler. This should be hooked into a terminal.Stream handler.
/// The hook/put/unhook functions are meant to be called from the
/// terminal.stream dcsHook, dcsPut, and dcsUnhook functions, respectively.
pub const Handler = struct {
    state: State = .{ .inactive = {} },

    /// Maximum bytes any DCS command can take. This is to prevent
    /// malicious input from causing us to allocate too much memory.
    /// This is arbitrarily set to 1MB today, increase if needed.
    max_bytes: usize = 1024 * 1024,

    pub fn deinit(self: *Handler) void {
        self.discard();
    }

    pub fn hook(self: *Handler, alloc: Allocator, dcs: DCS) ?Command {
        assert(self.state == .inactive);

        // Initialize our state to ignore in case of error
        self.state = .ignore;

        // Try to parse the hook.
        const hk_ = self.tryHook(alloc, dcs) catch |err| {
            log.info("error initializing DCS hook, will ignore hook err={}", .{err});
            return null;
        };
        const hk = hk_ orelse {
            log.info("unknown DCS hook: {}", .{dcs});
            return null;
        };

        self.state = hk.state;
        return hk.command;
    }

    const Hook = struct {
        state: State,
        command: ?Command = null,
    };

    fn tryHook(self: Handler, alloc: Allocator, dcs: DCS) !?Hook {
        return switch (dcs.intermediates.len) {
            0 => switch (dcs.final) {
                // Sixel graphics: ESC P [Pa;Pb;Pc] q <data> ST
                // final='q', no intermediates.
                'q' => sixel: {
                    // Pa (index 0) = pixel aspect ratio (ignored for rendering).
                    // Pb (index 1) = background select: 0=default, 1=black.
                    // Pc (index 2) = colour register count (0=256).
                    const ps: u16 = if (dcs.params.len >= 2) dcs.params[1] else 0;
                    const pc: u16 = if (dcs.params.len >= 3) dcs.params[2] else 0;
                    break :sixel .{
                        .state = .{
                            .sixel = .{
                                .params = .{ .ps = ps, .pc = pc },
                                .buffer = try .initCapacity(
                                    alloc,
                                    4096, // Sixel images can be large; start bigger
                                ),
                                .max_bytes = self.max_bytes,
                            },
                        },
                    };
                },

                // Tmux control mode
                'p' => tmux: {
                    if (comptime !build_options.tmux_control_mode) {
                        log.debug("tmux control mode not enabled in build, ignoring", .{});
                        break :tmux null;
                    }

                    // Tmux control mode must start with ESC P 1000 p
                    if (dcs.params.len != 1 or dcs.params[0] != 1000) break :tmux null;

                    break :tmux .{
                        .state = .{
                            .tmux = .{
                                .max_bytes = self.max_bytes,
                                .buffer = try .initCapacity(
                                    alloc,
                                    128, // Arbitrary choice to limit initial reallocs
                                ),
                            },
                        },
                        .command = .{ .tmux = .enter },
                    };
                },

                else => null,
            },

            1 => switch (dcs.intermediates[0]) {
                '+' => switch (dcs.final) {
                    // XTGETTCAP
                    // https://github.com/mitchellh/ghostty/issues/517
                    'q' => .{
                        .state = .{
                            .xtgettcap = try .initCapacity(
                                alloc,
                                128, // Arbitrary choice
                            ),
                        },
                    },

                    else => null,
                },

                '$' => switch (dcs.final) {
                    // DECRQSS
                    'q' => .{ .state = .{
                        .decrqss = .{},
                    } },

                    else => null,
                },

                else => null,
            },

            else => null,
        };
    }

    /// Put a byte into the DCS handler. This will return a command
    /// if a command needs to be executed.
    pub fn put(self: *Handler, byte: u8) ?Command {
        return self.tryPut(byte) catch |err| {
            // On error we just discard our state and ignore the rest
            log.info("error putting byte into DCS handler err={}", .{err});
            self.discard();
            self.state = .ignore;
            return null;
        };
    }

    fn tryPut(self: *Handler, byte: u8) !?Command {
        switch (self.state) {
            .inactive,
            .ignore,
            => {},

            .tmux => |*tmux| if (comptime build_options.tmux_control_mode) {
                return .{
                    .tmux = (try tmux.put(byte)) orelse return null,
                };
            } else unreachable,

            .xtgettcap => |*list| {
                if (list.written().len >= self.max_bytes) {
                    return error.OutOfMemory;
                }

                try list.writer.writeByte(byte);
            },

            .decrqss => |*buffer| {
                if (buffer.len >= buffer.data.len) {
                    return error.OutOfMemory;
                }

                buffer.data[buffer.len] = byte;
                buffer.len += 1;
            },

            .sixel => |*s| {
                if (s.buffer.written().len >= s.max_bytes) {
                    // Silently drop data that exceeds the limit.
                    // deinit the buffer before moving to .ignore state.
                    log.warn("sixel data exceeds max_bytes={}, dropping rest", .{s.max_bytes});
                    s.buffer.deinit();
                    self.state = .ignore;
                    return null;
                }
                try s.buffer.writer.writeByte(byte);
            },
        }

        return null;
    }

    pub fn unhook(self: *Handler) ?Command {
        // Note: we do NOT call deinit here on purpose because some commands
        // transfer memory ownership. If state needs cleanup, the switch
        // prong below should handle it.
        defer self.state = .inactive;

        return switch (self.state) {
            .inactive,
            .ignore,
            => null,

            .tmux => if (comptime build_options.tmux_control_mode) tmux: {
                self.state.deinit();
                break :tmux .{ .tmux = .exit };
            } else unreachable,

            .xtgettcap => |*list| xtgettcap: {
                // Note: purposely do not deinit our state here because
                // we copy it into the resulting command.
                const items = list.written();
                for (items, 0..) |b, i| items[i] = std.ascii.toUpper(b);
                break :xtgettcap .{ .xtgettcap = .{ .data = list.* } };
            },

            .decrqss => |buffer| .{ .decrqss = switch (buffer.len) {
                0 => .none,
                1 => switch (buffer.data[0]) {
                    'm' => .sgr,
                    'r' => .decstbm,
                    's' => .decslrm,
                    else => .none,
                },
                2 => switch (buffer.data[0]) {
                    ' ' => switch (buffer.data[1]) {
                        'q' => .decscusr,
                        else => .none,
                    },
                    else => .none,
                },
                else => unreachable,
            } },

            // Transfer ownership of the sixel buffer to the command.
            // The handler clears its state; the command owns the buffer.
            .sixel => |*s| .{
                .sixel = .{
                    .params = s.params,
                    .data = s.buffer,
                },
            },
        };
    }

    fn discard(self: *Handler) void {
        self.state.deinit();
        self.state = .inactive;
    }
};

pub const Command = union(enum) {
    /// XTGETTCAP
    xtgettcap: XTGETTCAP,

    /// DECRQSS
    decrqss: DECRQSS,

    /// Tmux control mode
    tmux: if (build_options.tmux_control_mode)
        terminal.tmux.ControlNotification
    else
        void,

    /// Sixel graphics data.  The `data` buffer contains the raw sixel byte
    /// stream (everything after the DCS `q` final byte, before ST).  Caller
    /// must call `deinit` to free the buffer.
    sixel: Sixel,

    pub const Sixel = struct {
        params: SixelParams,
        /// Raw sixel data buffer.  Ownership transferred from the DCS handler.
        data: std.Io.Writer.Allocating,
    };

    pub fn deinit(self: *Command) void {
        switch (self.*) {
            .xtgettcap => |*v| v.data.deinit(),
            .decrqss => {},
            .tmux => {},
            .sixel => |*v| v.data.deinit(),
        }
    }

    pub const XTGETTCAP = struct {
        data: std.Io.Writer.Allocating,
        i: usize = 0,

        /// Returns the next terminfo key being requested and null
        /// when there are no more keys. The returned value is NOT hex-decoded
        /// because we expect to use a comptime lookup table.
        pub fn next(self: *XTGETTCAP) ?[]const u8 {
            const items = self.data.written();
            if (self.i >= items.len) return null;
            var rem = items[self.i..];
            const idx = std.mem.indexOf(u8, rem, ";") orelse rem.len;

            // Note that if we're at the end, idx + 1 is len + 1 so we're over
            // the end but that's okay because our check above is >= so we'll
            // never read.
            self.i += idx + 1;

            return rem[0..idx];
        }
    };

    /// Supported DECRQSS settings
    pub const DECRQSS = enum {
        none,
        sgr,
        decscusr,
        decstbm,
        decslrm,
    };
};

const State = union(enum) {
    /// We're not in a DCS state at the moment.
    inactive,

    /// We're hooked, but its an unknown DCS command or one that went
    /// invalid due to some bad input, so we're ignoring the rest.
    ignore,

    /// XTGETTCAP
    xtgettcap: std.Io.Writer.Allocating,

    /// DECRQSS
    decrqss: struct {
        data: [2]u8 = undefined,
        len: u2 = 0,
    },

    /// Tmux control mode: https://github.com/tmux/tmux/wiki/Control-Mode
    tmux: if (build_options.tmux_control_mode)
        terminal.tmux.ControlParser
    else
        void,

    /// Sixel graphics: accumulate raw sixel data stream.
    sixel: struct {
        params: SixelParams,
        buffer: std.Io.Writer.Allocating,
        max_bytes: usize,
    },

    pub fn deinit(self: *State) void {
        switch (self.*) {
            .inactive,
            .ignore,
            => {},

            .xtgettcap => |*v| v.deinit(),
            .decrqss => {},
            .tmux => |*v| if (comptime build_options.tmux_control_mode) {
                v.deinit();
            } else unreachable,
            .sixel => |*v| v.buffer.deinit(),
        }
    }
};

test "unknown DCS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .final = 'A' }) == null);
    try testing.expect(h.state == .ignore);
    try testing.expect(h.unhook() == null);
    try testing.expect(h.state == .inactive);
}

test "XTGETTCAP command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP mixed case" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536d756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command multiple keys" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("536D756C78;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "XTGETTCAP command invalid data" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    for ("who;536D756C78") |byte| _ = h.put(byte);
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .xtgettcap);
    try testing.expectEqualStrings("WHO", cmd.xtgettcap.next().?);
    try testing.expectEqualStrings("536D756C78", cmd.xtgettcap.next().?);
    try testing.expect(cmd.xtgettcap.next() == null);
}

test "DECRQSS command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('m');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .sgr);
}

test "DECRQSS invalid command" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('z');
    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .decrqss);
    try testing.expect(cmd.decrqss == .none);

    h.discard();

    try testing.expect(h.hook(alloc, .{ .intermediates = "$", .final = 'q' }) == null);
    _ = h.put('"');
    _ = h.put(' ');
    _ = h.put('q');
    try testing.expect(h.unhook() == null);
}

test "tmux enter and implicit exit" {
    if (comptime !build_options.tmux_control_mode) return error.SkipZigTest;

    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    {
        var cmd = h.hook(alloc, .{ .params = &.{1000}, .final = 'p' }).?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .enter);
    }

    {
        var cmd = h.unhook().?;
        defer cmd.deinit();
        try testing.expect(cmd == .tmux);
        try testing.expect(cmd.tmux == .exit);
    }
}

test "sixel DCS hook recognized" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    // final='q', no intermediates → sixel
    const ret = h.hook(alloc, .{ .final = 'q' });
    try testing.expect(ret == null); // hook returns null (no immediate command)
    try testing.expect(h.state == .sixel);

    // Feed some data bytes
    _ = h.put('#');
    _ = h.put('0');
    _ = h.put('~');

    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .sixel);
    try testing.expectEqualStrings("#0~", cmd.sixel.data.written());
}

test "sixel DCS with params" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{};
    defer h.deinit();

    // Pa=0, Pb=1 (black bg), Pc=256
    _ = h.hook(alloc, .{ .params = &.{ 0, 1, 256 }, .final = 'q' });
    try testing.expect(h.state == .sixel);
    try testing.expectEqual(@as(u16, 1), h.state.sixel.params.ps);
    try testing.expectEqual(@as(u16, 256), h.state.sixel.params.pc);

    var cmd = h.unhook().?;
    defer cmd.deinit();
    try testing.expect(cmd == .sixel);
    try testing.expectEqual(@as(u16, 1), cmd.sixel.params.ps);
}

test "sixel DCS different from XTGETTCAP" {
    const testing = std.testing;
    const alloc = testing.allocator;

    // XTGETTCAP uses intermediate '+' before 'q', so it's different from sixel.
    var h: Handler = .{};
    defer h.deinit();
    try testing.expect(h.hook(alloc, .{ .intermediates = "+", .final = 'q' }) == null);
    try testing.expect(h.state == .xtgettcap);
    // unhook returns an owned Command; deinit to avoid leak.
    var cmd = h.unhook().?;
    cmd.deinit();
}

test "sixel DCS max_bytes limit" {
    const testing = std.testing;
    const alloc = testing.allocator;

    var h: Handler = .{ .max_bytes = 5 };
    defer h.deinit();

    _ = h.hook(alloc, .{ .final = 'q' });
    try testing.expect(h.state == .sixel);

    // Feed 6 bytes (1 over max_bytes=5) — should switch to ignore.
    _ = h.put('a');
    _ = h.put('b');
    _ = h.put('c');
    _ = h.put('d');
    _ = h.put('e');
    _ = h.put('f'); // this should trigger the overflow → .ignore

    // After the overflow, state is .ignore.
    try testing.expect(h.state == .ignore);

    // unhook() returns null for .ignore and resets state to .inactive.
    try testing.expect(h.unhook() == null);
    try testing.expect(h.state == .inactive);
}
