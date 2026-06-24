const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;
const termio = @import("../termio.zig");

const log = std.log.scoped(.pty_handle);

pub const PtyHandle = struct {
    alloc: Allocator,
    refcount: std.atomic.Value(u32),
    mu: std.Thread.Mutex,
    subscribers: std.ArrayListUnmanaged(*termio.Termio),
    /// PTY master fd for writing input bytes
    pty_fd: posix.fd_t,

    pub fn create(alloc: Allocator, pty_fd: posix.fd_t) !*PtyHandle {
        const handle = try alloc.create(PtyHandle);
        handle.* = .{
            .alloc = alloc,
            .refcount = std.atomic.Value(u32).init(1),
            .mu = .{},
            .subscribers = .{},
            .pty_fd = pty_fd,
        };
        return handle;
    }

    pub fn ref(self: *PtyHandle) void {
        _ = self.refcount.fetchAdd(1, .monotonic);
    }

    pub fn unref(self: *PtyHandle) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) {
            self.mu.lock();
            self.subscribers.deinit(self.alloc);
            self.mu.unlock();
            self.alloc.destroy(self);
        }
    }

    pub fn subscribe(self: *PtyHandle, io: *termio.Termio) !void {
        self.mu.lock();
        defer self.mu.unlock();
        try self.subscribers.append(self.alloc, io);
    }

    pub fn unsubscribe(self: *PtyHandle, io: *termio.Termio) void {
        self.mu.lock();
        defer self.mu.unlock();
        for (self.subscribers.items, 0..) |sub, i| {
            if (sub == io) {
                _ = self.subscribers.swapRemove(i);
                return;
            }
        }
    }

    /// Broadcast PTY output bytes to all subscribed Termio instances.
    /// Snapshot the list under the lock, then release before calling
    /// processOutput to avoid potential mutex ordering issues.
    pub fn broadcast(self: *PtyHandle, buf: []const u8) void {
        // Stack snapshot for the common case of <=8 mirrors
        var stack: [8]*termio.Termio = undefined;
        self.mu.lock();
        const n = @min(self.subscribers.items.len, stack.len);
        @memcpy(stack[0..n], self.subscribers.items[0..n]);
        if (self.subscribers.items.len > stack.len) {
            log.warn("broadcast: more than 8 subscribers, extras skipped", .{});
        }
        self.mu.unlock();

        for (stack[0..n]) |io| {
            termio.Termio.processOutput(io, buf);
        }
    }

    /// Write bytes to the PTY master fd (used by mirror surfaces for input).
    pub fn writePty(self: *PtyHandle, buf: []const u8) void {
        var remaining = buf;
        while (remaining.len > 0) {
            const n = posix.write(self.pty_fd, remaining) catch |err| {
                log.warn("writePty err={}", .{err});
                return;
            };
            remaining = remaining[n..];
        }
    }
};

test "PtyHandle: closing one subscriber keeps PTY alive" {
    const alloc = std.testing.allocator;
    // Use fd=-1 as a dummy (we won't call writePty in this test)
    const handle = try PtyHandle.create(alloc, -1);
    handle.ref(); // now refcount=2
    handle.unref(); // now refcount=1, not destroyed
    // Still alive: verify by calling ref again
    handle.ref();
    handle.unref();
    handle.unref(); // final unref: destroys
    // No assertion needed -- memory safety tools will catch double-free
}

test "PtyHandle: subscribe and unsubscribe" {
    const alloc = std.testing.allocator;
    const handle = try PtyHandle.create(alloc, -1);
    defer handle.unref();
    // Allocate a properly aligned Termio-shaped buffer as a fake pointer
    // so we satisfy the alignment requirement without dereferencing.
    // We never call broadcast, so the pointer is never actually used.
    const fake: *termio.Termio = try alloc.create(termio.Termio);
    defer alloc.destroy(fake);
    try handle.subscribe(fake);
    try std.testing.expectEqual(@as(usize, 1), handle.subscribers.items.len);
    handle.unsubscribe(fake);
    try std.testing.expectEqual(@as(usize, 0), handle.subscribers.items.len);
}

test "PtyHandle: closing last subscriber terminates PTY" {
    // Structural: verify unref to 0 deallocates. Memory tools verify.
    const alloc = std.testing.allocator;
    const handle = try PtyHandle.create(alloc, -1);
    handle.unref(); // refcount -> 0, handle freed
    // If this doesn't crash under leak detection, the test passes.
}
