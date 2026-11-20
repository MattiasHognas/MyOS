const std = @import("std");

pub fn build(b: *std.Build) void {
    const Feature = std.Target.x86.Feature;
    var sub = std.Target.Cpu.Feature.Set.empty;
    var add = std.Target.Cpu.Feature.Set.empty;
    inline for (.{ Feature.mmx, Feature.sse, Feature.sse2, Feature.avx, Feature.avx2 }) |f|
        sub.addFeature(@backingInt(f));
    add.addFeature(@backingInt(Feature.soft_float));

    const target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_sub = sub,
        .cpu_features_add = add,
    });

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = b.standardOptimizeOption(.{}),
            .code_model = .kernel,
            .red_zone = false,
            .pic = false,
            .sanitize_c = .off, // new
        }),
        .use_llvm = true, // new
        .use_lld = true, // new: LLD handles our linker script
    });

    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("linker.ld"));

    b.installArtifact(kernel);
}
