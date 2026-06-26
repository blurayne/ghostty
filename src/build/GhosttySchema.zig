//! GhosttySchema generates config.schema.json and derived editor completion
//! files (Sublime Text, VS Code) from Ghostty's comptime config metadata.
const GhosttySchema = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

/// Top-level step; depends on all three install steps (JSON + Sublime + VS Code).
step: *std.Build.Step,

pub fn init(b: *std.Build, deps: *const SharedDeps) !GhosttySchema {
    const exe = b.addExecutable(.{
        .name = "schemagen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/schemagen.zig"),
            .target = b.graph.host,
            .strip = false,
            .omit_frame_pointer = false,
            .unwind_tables = .sync,
        }),
    });

    // schemagen needs the same build_options as helpgen (for Config.zig
    // which transitively imports build_config.zig → build_options).
    const schema_config = blk: {
        var copy = deps.config.*;
        copy.exe_entrypoint = .helpgen; // any non-ghostty entrypoint is fine
        break :blk copy;
    };
    const options = b.addOptions();
    try schema_config.addOptions(options);
    exe.root_module.addOptions("build_options", options);

    // schemagen also needs the generated help_strings module for doc strings.
    deps.help_strings.addImport(exe);

    const run = b.addRunArtifact(exe);
    const json_out = run.captureStdOut();

    // Primary output: config.schema.json
    const install_json = b.addInstallFile(
        json_out,
        "share/ghostty/schema/config.schema.json",
    );

    // Derived output: Sublime Text completions
    const run_sublime = b.addSystemCommand(&.{
        "python3",
        "src/build/schema/gen_sublime_completions.py",
    });
    run_sublime.addFileArg(json_out);
    const sublime_out = run_sublime.captureStdOut();
    const install_sublime = b.addInstallFile(
        sublime_out,
        "share/ghostty/schema/ghostty.sublime-completions",
    );

    // Derived output: VS Code snippets
    const run_vscode = b.addSystemCommand(&.{
        "python3",
        "src/build/schema/gen_vscode_snippets.py",
    });
    run_vscode.addFileArg(json_out);
    const vscode_out = run_vscode.captureStdOut();
    const install_vscode = b.addInstallFile(
        vscode_out,
        "share/ghostty/schema/ghostty-vscode-snippets.json",
    );

    // Aggregate step: all three installs must complete
    const all = b.allocator.create(std.Build.Step) catch @panic("OOM");
    all.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "schema-all",
        .owner = b,
        .makeFn = struct {
            fn make(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {}
        }.make,
    });
    all.dependOn(&install_json.step);
    all.dependOn(&install_sublime.step);
    all.dependOn(&install_vscode.step);

    return .{ .step = all };
}

pub fn install(self: *const GhosttySchema) void {
    const b = self.step.owner;
    b.getInstallStep().dependOn(self.step);
}
