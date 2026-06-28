//! ghostty-config-lsp — Language Server for Ghostty config files.
//!
//! Reads config.schema.json (embedded at compile time via build system) and
//! speaks LSP 3.17 over stdio. Implements:
//!   - initialize / initialized / shutdown / exit
//!   - textDocument/completion
//!   - textDocument/hover
//!   - textDocument/diagnostic (pull diagnostics, LSP 3.17)
//!   - textDocument/didOpen, didChange, didClose

const std = @import("std");
const jsonrpc = @import("jsonrpc.zig");
const schema_mod = @import("schema.zig");
const server_mod = @import("server.zig");

/// The config.schema.json embedded at compile time.
/// The build system injects this via addAnonymousImport("config_schema", ...)
/// pointing to the lazy path produced by the schema generator.
const embedded_schema_module = @import("config_schema");
const embedded_schema: []const u8 = embedded_schema_module.data;

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse the embedded schema.
    var schema = try schema_mod.parse(allocator, embedded_schema);
    defer schema.deinit();

    var server = server_mod.Server.init(allocator, &schema);
    defer server.deinit();

    // Zig 0.15 IO: use buffered readers/writers for stdio.
    var stdin_buf: [4096]u8 = undefined;
    var stdin_reader = std.fs.File.stdin().reader(&stdin_buf);
    const stdin = &stdin_reader.interface;

    var stdout_buf_arr: [65536]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writerStreaming(&stdout_buf_arr);
    const stdout_bw = &stdout_writer.interface;

    // Stderr is unbuffered for immediate diagnostic output.
    const stderr_file = std.fs.File.stderr();

    stderr_file.writeAll("[ghostty-lsp] started\n") catch {};

    while (true) {
        // Read next message
        const msg_bytes = jsonrpc.readMessage(allocator, stdin) catch |err| {
            _ = err;
            break;
        } orelse {
            // EOF — client closed the connection.
            break;
        };
        defer allocator.free(msg_bytes);

        const req = jsonrpc.parseRequest(allocator, msg_bytes) catch |err| {
            _ = err;
            continue;
        };
        defer jsonrpc.freeRequest(allocator, req);

        const response = handleRequest(allocator, &server, &req) catch |err| {
            _ = err;
            // Send internal error response if request (not notification).
            if (req.id != .null) {
                const err_resp = try formatErrorResponse(allocator, req.id, -32603, "Internal error");
                defer allocator.free(err_resp);
                try jsonrpc.writeMessage(stdout_bw, err_resp);
                try stdout_writer.end();
            }
            continue;
        };

        if (response) |resp| {
            defer allocator.free(resp);
            try jsonrpc.writeMessage(stdout_bw, resp);
            try stdout_writer.end();
        }

        if (server.shutdown_requested and req.id == .null and std.mem.eql(u8, req.method, "exit")) {
            break;
        }
    }
}

fn handleRequest(
    allocator: std.mem.Allocator,
    server: *server_mod.Server,
    req: *const jsonrpc.Request,
) !?[]const u8 {
    const method = req.method;

    if (std.mem.eql(u8, method, "initialize")) {
        return try handleInitialize(allocator, req);
    } else if (std.mem.eql(u8, method, "initialized")) {
        return null; // notification, no response
    } else if (std.mem.eql(u8, method, "shutdown")) {
        server.shutdown_requested = true;
        return try formatResult(allocator, req.id, "null");
    } else if (std.mem.eql(u8, method, "exit")) {
        return null;
    } else if (std.mem.eql(u8, method, "textDocument/didOpen")) {
        try handleDidOpen(allocator, server, req);
        return null;
    } else if (std.mem.eql(u8, method, "textDocument/didChange")) {
        try handleDidChange(allocator, server, req);
        return null;
    } else if (std.mem.eql(u8, method, "textDocument/didClose")) {
        try handleDidClose(allocator, server, req);
        return null;
    } else if (std.mem.eql(u8, method, "textDocument/completion")) {
        return try handleCompletion(allocator, server, req);
    } else if (std.mem.eql(u8, method, "textDocument/hover")) {
        return try handleHover(allocator, server, req);
    } else if (std.mem.eql(u8, method, "textDocument/diagnostic")) {
        return try handleDiagnostic(allocator, server, req);
    } else if (std.mem.eql(u8, method, "$/cancelRequest")) {
        return null; // ignore
    } else {
        // Method not found — only respond if it's a request (has an id).
        if (req.id != .null) {
            return try formatErrorResponse(allocator, req.id, -32601, "Method not found");
        }
        return null;
    }
}

// ---------------------------------------------------------------------------
// Handler implementations
// ---------------------------------------------------------------------------

fn handleInitialize(allocator: std.mem.Allocator, req: *const jsonrpc.Request) !?[]const u8 {
    const capabilities =
        \\{"textDocumentSync":{"openClose":true,"change":1},"completionProvider":{"triggerCharacters":["="," "],"resolveProvider":false},"hoverProvider":true,"diagnosticProvider":{"identifier":"ghostty","interFileDependencies":false,"workspaceDiagnostics":false}}
    ;
    const result = try std.fmt.allocPrint(allocator,
        \\{{"capabilities":{s},"serverInfo":{{"name":"ghostty-config-lsp","version":"0.1.0"}}}}
    , .{capabilities});
    defer allocator.free(result);
    return try formatResult(allocator, req.id, result);
}

fn handleDidOpen(allocator: std.mem.Allocator, server: *server_mod.Server, req: *const jsonrpc.Request) !void {
    const params = req.params_raw orelse return;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const td = obj.get("textDocument") orelse return;
    const td_obj = td.object;
    const uri = (td_obj.get("uri") orelse return).string;
    const text = (td_obj.get("text") orelse return).string;
    try server.openDocument(uri, text);
}

fn handleDidChange(allocator: std.mem.Allocator, server: *server_mod.Server, req: *const jsonrpc.Request) !void {
    const params = req.params_raw orelse return;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const td = obj.get("textDocument") orelse return;
    const uri = (td.object.get("uri") orelse return).string;
    const changes = (obj.get("contentChanges") orelse return).array;
    if (changes.items.len == 0) return;
    // Full-sync mode (change=1): take the last change's text.
    const last_change = changes.items[changes.items.len - 1];
    const text = (last_change.object.get("text") orelse return).string;
    try server.updateDocument(uri, text);
}

fn handleDidClose(allocator: std.mem.Allocator, server: *server_mod.Server, req: *const jsonrpc.Request) !void {
    const params = req.params_raw orelse return;
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const td = obj.get("textDocument") orelse return;
    const uri = (td.object.get("uri") orelse return).string;
    server.closeDocument(uri);
}

fn handleCompletion(allocator: std.mem.Allocator, server: *server_mod.Server, req: *const jsonrpc.Request) !?[]const u8 {
    const params = req.params_raw orelse return try formatResult(allocator, req.id, "[]");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const td = obj.get("textDocument") orelse return try formatResult(allocator, req.id, "[]");
    const uri = (td.object.get("uri") orelse return try formatResult(allocator, req.id, "[]")).string;
    const pos = (obj.get("position") orelse return try formatResult(allocator, req.id, "[]")).object;
    const line_num: u32 = @intCast((pos.get("line") orelse return try formatResult(allocator, req.id, "[]")).integer);
    const character: u32 = @intCast((pos.get("character") orelse return try formatResult(allocator, req.id, "[]")).integer);

    const items = try server.completion(allocator, uri, line_num, character);
    defer allocator.free(items);

    // Wrap in CompletionList
    const result = try std.fmt.allocPrint(allocator, "{{\"isIncomplete\":false,\"items\":{s}}}", .{items});
    defer allocator.free(result);
    return try formatResult(allocator, req.id, result);
}

fn handleHover(allocator: std.mem.Allocator, server: *server_mod.Server, req: *const jsonrpc.Request) !?[]const u8 {
    const params = req.params_raw orelse return try formatResult(allocator, req.id, "null");
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const td = obj.get("textDocument") orelse return try formatResult(allocator, req.id, "null");
    const uri = (td.object.get("uri") orelse return try formatResult(allocator, req.id, "null")).string;
    const pos = (obj.get("position") orelse return try formatResult(allocator, req.id, "null")).object;
    const line_num: u32 = @intCast((pos.get("line") orelse return try formatResult(allocator, req.id, "null")).integer);
    const character: u32 = @intCast((pos.get("character") orelse return try formatResult(allocator, req.id, "null")).integer);

    const hover_result = try server.hover(allocator, uri, line_num, character);
    defer allocator.free(hover_result);
    return try formatResult(allocator, req.id, hover_result);
}

fn handleDiagnostic(allocator: std.mem.Allocator, server: *server_mod.Server, req: *const jsonrpc.Request) !?[]const u8 {
    const params = req.params_raw orelse return try formatResult(allocator, req.id,
        \\{"kind":"full","items":[]}
    );
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, params, .{});
    defer parsed.deinit();
    const obj = parsed.value.object;
    const td = obj.get("textDocument") orelse return try formatResult(allocator, req.id,
        \\{"kind":"full","items":[]}
    );
    const uri = (td.object.get("uri") orelse return try formatResult(allocator, req.id,
        \\{"kind":"full","items":[]}
    )).string;

    const diags = try server.diagnostics(allocator, uri);
    defer allocator.free(diags);

    const result = try std.fmt.allocPrint(allocator, "{{\"kind\":\"full\",\"items\":{s}}}", .{diags});
    defer allocator.free(result);
    return try formatResult(allocator, req.id, result);
}

// ---------------------------------------------------------------------------
// JSON formatting helpers
// ---------------------------------------------------------------------------

fn formatResult(allocator: std.mem.Allocator, id: jsonrpc.Request.Id, result_json: []const u8) ![]const u8 {
    const id_str = try idToString(allocator, id);
    defer allocator.free(id_str);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}",
        .{ id_str, result_json },
    );
}

fn formatErrorResponse(
    allocator: std.mem.Allocator,
    id: jsonrpc.Request.Id,
    code: i32,
    message: []const u8,
) ![]const u8 {
    const id_str = try idToString(allocator, id);
    defer allocator.free(id_str);
    return try std.fmt.allocPrint(
        allocator,
        "{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":\"{s}\"}}}}",
        .{ id_str, code, message },
    );
}

fn idToString(allocator: std.mem.Allocator, id: jsonrpc.Request.Id) ![]const u8 {
    return switch (id) {
        .number => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .string => |s| std.fmt.allocPrint(allocator, "\"{s}\"", .{s}),
        .null => allocator.dupe(u8, "null"),
    };
}
