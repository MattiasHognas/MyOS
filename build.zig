const std = @import("std");

pub fn build(b: *std.Build) void {
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Run only tests matching these filters",
    ) orelse &.{};
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

    const kernel = kernelArtifact(b, "kernel.elf", target, optimize, false);
    b.installArtifact(kernel);
    userProgram(b, "hello", target, optimize);
    userProgram(b, "sh", target, optimize);

    const test_kernel = kernelArtifact(b, "kernel-test.elf", target, .Debug, true);
    // Both consumers must share one module instance.
    const qemu_exit = b.createModule(.{
        .root_source_file = b.path("tests/support/qemu_exit.zig"),
        .target = target,
        .optimize = .Debug,
    });
    const kernel_tests = b.createModule(.{
        .root_source_file = b.path("tests/kernel/main.zig"),
        .target = target,
        .optimize = .Debug,
    });
    kernel_tests.addImport("qemu_exit", qemu_exit);
    test_kernel.root_module.addImport("kernel_tests", kernel_tests);
    test_kernel.root_module.addImport("qemu_exit", qemu_exit);

    const install_test_kernel = b.addInstallArtifact(test_kernel, .{});
    const test_kernel_step = b.step("test-kernel", "Compile the QEMU test kernel");
    test_kernel_step.dependOn(&install_test_kernel.step);

    const host_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .filters = test_filters,
    });
    host_tests.root_module.addImport("vfs", b.createModule(.{
        .root_source_file = b.path("src/kernel/vfs.zig"),
        .target = b.graph.host,
        .optimize = .Debug,
    }));
    const run_host_tests = b.addRunArtifact(host_tests);
    const host_step = b.step("test-host", "Run native unit tests with fakes");
    host_step.dependOn(&run_host_tests.step);

    // test-qemu.sh packages already installed binaries; it never calls zig build.
    const run_qemu = b.addSystemCommand(&.{ "bash", "test-qemu.sh" });
    run_qemu.step.dependOn(&install_test_kernel.step);
    run_qemu.step.dependOn(b.getInstallStep());
    const qemu_step = b.step("test-qemu", "Run real kernel tests under QEMU");
    qemu_step.dependOn(&run_qemu.step);

    const all = b.step("test", "Run host tests and QEMU kernel tests");
    all.dependOn(&run_host_tests.step);
    all.dependOn(&run_qemu.step);
}

fn kernelArtifact(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    is_test: bool,
) *std.Build.Step.Compile {
    const kernel = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .code_model = .kernel,
            .red_zone = false,
            .pic = false,
            .sanitize_c = .off,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("linker.ld"));
    const options = b.addOptions();
    options.addOption(bool, "is_test", is_test);
    kernel.root_module.addOptions("build_options", options);
    return kernel;
}

fn userProgram(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) void {
    const exe = b.addExecutable(.{
        .name = b.fmt("{s}.elf", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(b.fmt("app/{s}.zig", .{name})),
            .target = target,
            .optimize = optimize,
            .pic = false,
            .sanitize_c = .off,
            .strip = true,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    exe.entry = .{ .symbol_name = "_start" };
    exe.setLinkerScript(b.path("app/linker.ld"));
    b.installArtifact(exe);
}
