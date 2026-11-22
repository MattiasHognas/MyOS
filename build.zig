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

    const kopts: KernelOptions = .{
        .log_level = b.option(
            std.log.Level,
            "log-level",
            "Kernel log level: err, warn, info or debug (default: debug in Debug builds, info otherwise)",
        ) orelse if (optimize == .debug) .debug else .info,
        .assertions = b.option(
            bool,
            "assertions",
            "Enable kernel subsystem assertions (default: true)",
        ) orelse true,
        .alloc_debug = b.option(
            bool,
            "alloc-debug",
            "Log every kernel heap allocation and free (default: false)",
        ) orelse false,
    };

    const kernel = kernelArtifact(b, "kernel.elf", target, optimize, false, kopts);
    b.installArtifact(kernel);
    userProgram(b, "hello", target, optimize);
    userProgram(b, "sh", target, optimize);

    // Generate API documentation. Autodoc uses `<artifact name>.zig` (or the
    // first file it sees) as the module root, so the docs come from a copy of
    // the kernel named "main" to make src/main.zig the entry page. Only built
    // by `zig build docs`.
    const docs_kernel = kernelArtifact(b, "main", target, optimize, false, kopts);
    const install_docs = b.addInstallDirectory(.{
        .source_dir = docs_kernel.getEmittedDocs(),
        .install_dir = .prefix,
        .install_subdir = "docs",
    });

    const docs_step = b.step(
        "docs",
        "Generate kernel API documentation",
    );

    docs_step.dependOn(&install_docs.step);

    // The test kernel follows -Doptimize so CI can run the QEMU tests against
    // both debug and optimized builds.
    const test_kernel = kernelArtifact(b, "kernel-test.elf", target, optimize, true, kopts);
    // Both consumers must share one module instance.
    const qemu_exit = b.createModule(.{
        .root_source_file = b.path("tests/support/qemu_exit.zig"),
        .target = target,
        .optimize = optimize,
    });
    const kernel_tests = b.createModule(.{
        .root_source_file = b.path("tests/kernel/main.zig"),
        .target = target,
        .optimize = optimize,
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
    // Hardware-independent kernel modules, compiled natively for the host tests.
    inline for (.{
        .{ "vfs", "src/kernel/vfs.zig" },
        .{ "symbols", "src/kernel/debug/symbols.zig" },
        .{ "log_format", "src/kernel/debug/log_format.zig" },
    }) |m| {
        host_tests.root_module.addImport(m[0], b.createModule(.{
            .root_source_file = b.path(m[1]),
            .target = b.graph.host,
            .optimize = .Debug,
        }));
    }
    const run_host_tests = b.addRunArtifact(host_tests);
    const host_step = b.step("test-host", "Run native unit tests with fakes");
    host_step.dependOn(&run_host_tests.step);

    // Host-code coverage with kcov (must be installed). Report: zig-out/coverage/index.html
    const run_coverage = b.addSystemCommand(&.{ "kcov", "--clean" });
    run_coverage.addPrefixedDirectoryArg("--include-path=", b.path("src"));
    const coverage_dir = run_coverage.addOutputDirectoryArg("coverage");
    run_coverage.addArtifactArg(host_tests);
    const install_coverage = b.addInstallDirectory(.{
        .source_dir = coverage_dir,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    });
    const coverage_step = b.step("coverage", "Run host tests under kcov and write zig-out/coverage");
    coverage_step.dependOn(&install_coverage.step);

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

/// Kernel configuration exposed to the kernel as `build_options`.
const KernelOptions = struct {
    log_level: std.log.Level,
    assertions: bool,
    alloc_debug: bool,
};

fn kernelArtifact(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    is_test: bool,
    kopts: KernelOptions,
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
            // Keep RBP frame chains so panics and faults can print backtraces.
            .omit_frame_pointer = false,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("linker.ld"));
    const options = b.addOptions();
    options.addOption(bool, "is_test", is_test);
    options.addOption(std.log.Level, "log_level", kopts.log_level);
    options.addOption(bool, "assertions", kopts.assertions);
    options.addOption(bool, "alloc_debug", kopts.alloc_debug);
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
