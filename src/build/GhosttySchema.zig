//! GhosttySchema generates config.schema.json — a machine-readable
//! description of every user-facing Ghostty configuration field.
const GhosttySchema = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");

/// The install step that produces zig-out/share/ghostty/schema/config.schema.json.
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

    const install = b.addInstallFile(
        json_out,
        "share/ghostty/schema/config.schema.json",
    );

    return .{ .step = &install.step };
}

pub fn install(self: *const GhosttySchema) void {
    const b = self.step.owner;
    b.getInstallStep().dependOn(self.step);
}
