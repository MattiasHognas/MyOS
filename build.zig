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

    const optimize = b.standardOptimizeOption(.{});

    const hello = b.addExecutable(.{
        .name = "hello.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("app/hello.zig"),
            .target = target,
            .optimize = optimize,
            .pic = false,
            .sanitize_c = .off,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    hello.entry = .{ .symbol_name = "_start" };
    hello.setLinkerScript(b.path("app/linker.ld"));
    b.installArtifact(hello);

    const kernel = b.addExecutable(.{
        .name = "kernel.elf",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
            .red_zone = false,
            .pic = false,
            .sanitize_c = .off,
        }),
        .use_llvm = true, // new
        .use_lld = true, // new: LLD handles our linker script
    });
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("linker.ld"));
    b.installArtifact(kernel);
}
