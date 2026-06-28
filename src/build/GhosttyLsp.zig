//! GhosttyLsp builds the `ghostty-config-lsp` Language Server binary.
//!
//! The binary embeds `config.schema.json` (produced by the GhosttySchema step)
//! via a generated Zig shim module so it ships as a zero-dependency executable.
const GhosttyLsp = @This();

const std = @import("std");
const SharedDeps = @import("SharedDeps.zig");
const GhosttySchema = @import("GhosttySchema.zig");

/// The compiled LSP executable.
exe: *std.Build.Step.Compile,

/// Install step that places the binary under `bin/ghostty-config-lsp`.
install_step: *std.Build.Step,

pub fn init(
    b: *std.Build,
    deps: *const SharedDeps,
    schema: *const GhosttySchema,
) !GhosttyLsp {
    // The schema JSON is produced by the emit-config-schema step.
    // We use WriteFiles to copy it into the build cache under a predictable
    // name, then generate a tiny Zig shim that @embedFile the JSON.
    const wf = b.addWriteFiles();
    // Copy the schema JSON next to the shim so @embedFile resolves correctly.
    _ = wf.addCopyFile(schema.json_output, "config.schema.json");
    // Generate the shim: pub const data: []const u8 = @embedFile("config.schema.json");
    const shim = wf.add(
        "config_schema.zig",
        \\pub const data: []const u8 = @embedFile("config.schema.json");
        \\
    );

    const exe = b.addExecutable(.{
        .name = "ghostty-config-lsp",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/lsp/main.zig"),
            .target = deps.config.target,
            .optimize = deps.config.optimize,
            .strip = deps.config.strip,
        }),
    });

    // Inject the schema shim as "config_schema" import.
    exe.root_module.addAnonymousImport("config_schema", .{
        .root_source_file = shim,
    });

    // The LSP binary doesn't import build_options directly; skip the unused import.

    const install_artifact = b.addInstallArtifact(exe, .{});

    // Aggregate step
    const agg = b.allocator.create(std.Build.Step) catch @panic("OOM");
    agg.* = std.Build.Step.init(.{
        .id = .custom,
        .name = "ghostty-lsp-all",
        .owner = b,
        .makeFn = struct {
            fn make(_: *std.Build.Step, _: std.Build.Step.MakeOptions) anyerror!void {}
        }.make,
    });
    agg.dependOn(&install_artifact.step);

    return .{
        .exe = exe,
        .install_step = agg,
    };
}

pub fn install(self: *const GhosttyLsp) void {
    const b = self.install_step.owner;
    b.getInstallStep().dependOn(self.install_step);
}
