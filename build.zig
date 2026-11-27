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

    // User programs use SSE2, like every x86-64 program built for Linux; the
    // kernel saves and restores their registers (src/arch/x86_64/fpu.zig).
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .x86_64,
        .os_tag = .freestanding,
        .abi = .none,
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
        .allow_meltdown = b.option(
            bool,
            "allow-meltdown",
            "Boot on CPUs affected by Meltdown, where user programs can read kernel memory, instead of refusing (default: false)",
        ) orelse false,
        .poison = b.option(
            bool,
            "poison",
            "Fill freed heap memory and freed pages with a pattern, and check it on reuse (default: true in Debug builds, false otherwise; always on in the test kernel)",
        ) orelse (optimize == .debug),
        .stack_usage = b.option(
            bool,
            "stack-usage",
            "Measure how much of each kernel stack is used (default: true in Debug builds, false otherwise; always on in the test kernel)",
        ) orelse (optimize == .debug),
        .bench = b.option(
            bool,
            "bench",
            "Build the test kernel as a release kernel is built, without the poisoning and stack measuring it otherwise always has: for tools/bench, so that MyOS is measured as it ships (default: false)",
        ) orelse false,
        .version = b.option(
            []const u8,
            "version",
            "Version shown in the boot banner; set by release builds (default: dev)",
        ) orelse "dev",
    };

    // Compare the tools with tools.versions: an error in CI, a warning
    // elsewhere. Every build checks Zig itself; the steps that run QEMU or
    // kcov check those too (below).
    const check_zig = b.addSystemCommand(&.{ "bash", "scripts/check-tools.sh", "zig" });
    b.getInstallStep().dependOn(&check_zig.step);

    const kernel = kernelArtifact(b, "kernel.elf", target, optimize, false, kopts);
    b.installArtifact(kernel);
    // Syscall numbers and error values, shared by the kernel and user programs.
    const abi = b.createModule(.{
        .root_source_file = b.path("src/abi/linux.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    const exe_hello = userProgram(b, "hello", "app/hello.zig", 0x80_0000, user_target, optimize);
    exe_hello.root_module.addImport("abi", abi);
    b.installArtifact(exe_hello);

    // MyOS's own programs: ordinary Linux programs, built with the Zig
    // standard library for x86_64-linux, packaged as /usr/bin/<name>.
    const linux_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .none });
    // Built optimized with the safety checks on even in a Debug build, and
    // without symbols: a Debug build of a standard-library program is
    // 11 MB, and the image holds them all in memory.
    const app_optimize: std.builtin.OptimizeMode = if (optimize == .debug) .ReleaseSafe else optimize;
    const util = b.createModule(.{
        .root_source_file = b.path("app/util.zig"),
        .target = linux_target,
        .optimize = app_optimize,
    });
    const sh_words = b.createModule(.{
        .root_source_file = b.path("app/sh_words.zig"),
        .target = linux_target,
        .optimize = app_optimize,
    });
    inline for (.{
        "sh", "init",  "echo", "cat",   "ls",    "pwd", "mkdir", "rmdir",
        "rm", "clear", "true", "false", "sleep", "env", "kill",  "ps",
    }) |name| {
        const exe = b.addExecutable(.{
            .name = "bin-" ++ name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("app/bin/" ++ name ++ ".zig"),
                .target = linux_target,
                .optimize = app_optimize,
                .strip = true,
            }),
        });
        exe.root_module.addImport("util", util);
        exe.root_module.addImport("sh_words", sh_words);
        b.installArtifact(exe); // scripts/build.sh puts zig-out/bin/bin-<name> at /usr/bin/<name>
    }
    // The benchmark of tools/bench, as /usr/bin/bench: always optimized,
    // since its numbers are compared with Linux's.
    const bench_exe = b.addExecutable(.{
        .name = "bin-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bench/bench.zig"),
            .target = linux_target,
            .optimize = .ReleaseFast,
            .strip = true,
        }),
    });
    b.installArtifact(bench_exe);
    // A few utilities in plain C, built as any Linux toolchain builds them
    // (Zig's clang and musl, statically linked), packaged next to them.
    const musl_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .linux, .abi = .musl });
    inline for (.{ "wc", "head" }) |name| {
        const exe = b.addExecutable(.{
            .name = "bin-" ++ name,
            .root_module = b.createModule(.{
                .target = musl_target,
                .optimize = .ReleaseSmall,
                .link_libc = true,
                .strip = true,
            }),
            .linkage = .static,
        });
        exe.root_module.addCSourceFile(.{ .file = b.path("app/c/" ++ name ++ ".c"), .flags = &.{ "-std=c11", "-Wall", "-Werror" } });
        b.installArtifact(exe);
    }

    // User-mode test programs, packaged into the test initrd as /test/<name>.
    const user_lib = b.createModule(.{
        .root_source_file = b.path("app/lib.zig"),
        .target = user_target,
        .optimize = optimize,
    });
    user_lib.addImport("abi", abi);
    inline for (.{
        "syscalls",   "kernel_read", "privileged", "write_text",     "user_pointers",
        "entry_regs", "umip",        "div_zero",   "invalid_opcode", "syscall_abi",
        "preempt",    "gs_base",     "fpu",        "fpu_clean",      "fuzz",
        "bad_return", "single_step", "recurse",    "open_count",     "run_many",
        "getchar",    "zero_pages",  "linux_abi",  "vm",             "threads",
        "pipes",      "files",       "alloc",      "tmp",            "terminal",
        "signals",    "epoll",       "fsgsbase",   "fork",           "exec",
        "clock",      "jobs",        "errors",     "sigqueue",       "flock",
    }) |name| {
        const exe = userProgram(b, "test-" ++ name, "tests/user/" ++ name ++ ".zig", 0x40_0000, user_target, optimize);
        exe.root_module.addImport("lib", user_lib);
        exe.root_module.addImport("abi", abi);
        b.installArtifact(exe); // scripts/build.sh --package-test picks them up from zig-out/bin
    }

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

    const host_tests = hostTests(b, test_filters, false);
    const run_host_tests = b.addRunArtifact(host_tests);
    const host_step = b.step("test-host", "Run native unit tests with fakes");
    host_step.dependOn(&run_host_tests.step);

    // For the editor's "Debug Test": install the host tests where the VS Code
    // Zig extension looks for them (zig.debugTestArgs in .vscode/settings.json).
    // LLVM build, since debuggers read its debug info best (shared with coverage).
    const llvm_host_tests = hostTests(b, test_filters, true);
    const install_debug_tests = b.addInstallArtifact(llvm_host_tests, .{ .dest_sub_path = "debug-unit-tests" });
    const debug_tests_step = b.step("debug-test-host", "Build the host tests for a debugger (zig-out/bin/debug-unit-tests)");
    debug_tests_step.dependOn(&install_debug_tests.step);

    // Coverage-guided fuzzing of the host tests that call `std.testing.fuzz`:
    // `zig build fuzz-host --fuzz` (docs/testing.md). The instrumentation
    // needs the LLVM backend, so it runs the LLVM build of the tests.
    const run_fuzz_tests = b.addRunArtifact(llvm_host_tests);
    const fuzz_step = b.step("fuzz-host", "Run the host tests for fuzzing: add --fuzz, or --fuzz=<iterations>");
    fuzz_step.dependOn(&run_fuzz_tests.step);

    // Host-code coverage with kcov (scripts/coverage.sh explains how to install
    // it if it is missing). Report: zig-out/coverage/index.html
    const check_kcov = b.addSystemCommand(&.{ "bash", "scripts/check-tools.sh", "zig", "kcov" });
    const run_coverage = b.addSystemCommand(&.{"bash"});
    run_coverage.step.dependOn(&check_kcov.step);
    run_coverage.addFileArg(b.path("scripts/coverage.sh")); // tracked: edits re-run coverage
    run_coverage.addDirectoryArg(b.path("src"));
    const coverage_dir = run_coverage.addOutputDirectoryArg("coverage");
    // kcov can't read the debug info of Zig's own x86 backend (it reports 0
    // lines), so coverage uses a separate LLVM build of the host tests.
    run_coverage.addArtifactArg(llvm_host_tests);
    const install_coverage = b.addInstallDirectory(.{
        .source_dir = coverage_dir,
        .install_dir = .prefix,
        .install_subdir = "coverage",
    });
    const coverage_step = b.step("coverage", "Run host tests under kcov and write zig-out/coverage");
    coverage_step.dependOn(&install_coverage.step);

    // scripts/test-qemu.sh packages already installed binaries; it never calls zig build.
    const run_qemu = b.addSystemCommand(&.{ "bash", "scripts/test-qemu.sh" });
    const check_qemu_tools = b.addSystemCommand(&.{ "bash", "scripts/check-tools.sh", "zig", "limine", "qemu", "xorriso" });
    run_qemu.step.dependOn(&check_qemu_tools.step);
    run_qemu.step.dependOn(&install_test_kernel.step);
    run_qemu.step.dependOn(b.getInstallStep());
    const qemu_step = b.step("test-qemu", "Run real kernel tests under QEMU");
    qemu_step.dependOn(&run_qemu.step);

    // No kernel function may have a stack frame that could step over a kernel
    // stack's guard page. Checks the installed kernels, like the QEMU tests.
    const run_frames = b.addSystemCommand(&.{ "bash", "scripts/check-frames.sh", "zig-out/bin/kernel.elf", "zig-out/bin/kernel-test.elf" });
    run_frames.step.dependOn(&install_test_kernel.step);
    run_frames.step.dependOn(b.getInstallStep());
    const frames_step = b.step("check-frames", "Check the stack frame sizes of the kernel and the test kernel");
    frames_step.dependOn(&run_frames.step);

    // The normal kernel must call its syscall dispatcher directly; only the
    // test kernel has a replaceable handler. Checks the installed kernels.
    const run_dispatch = b.addSystemCommand(&.{ "bash", "scripts/check-dispatch.sh", "zig-out/bin/kernel.elf", "zig-out/bin/kernel-test.elf" });
    run_dispatch.step.dependOn(&install_test_kernel.step);
    run_dispatch.step.dependOn(b.getInstallStep());
    const dispatch_step = b.step("check-dispatch", "Check that the normal kernel has no replaceable syscall handler");
    dispatch_step.dependOn(&run_dispatch.step);

    // Model checks of the blocking protocols (docs/locking.md): the checker
    // in tools/modelcheck with its own tests, and the models in tests/models.
    // Optimized, since a check visits every state of a model.
    const modelcheck = b.createModule(.{
        .root_source_file = b.path("tools/modelcheck/modelcheck.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const modelcheck_tests = b.addTest(.{ .root_module = modelcheck, .filters = test_filters });
    const model_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/models/main.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
        .filters = test_filters,
    });
    model_tests.root_module.addImport("modelcheck", modelcheck);
    const run_modelcheck_tests = b.addRunArtifact(modelcheck_tests);
    const run_model_tests = b.addRunArtifact(model_tests);
    const models_step = b.step("check-models", "Model-check the kernel's blocking protocols");
    models_step.dependOn(&run_modelcheck_tests.step);
    models_step.dependOn(&run_model_tests.step);

    const all = b.step("test", "Run host tests, the model checks, the stack frame and syscall dispatch checks and QEMU kernel tests");
    all.dependOn(&run_host_tests.step);
    all.dependOn(&run_modelcheck_tests.step);
    all.dependOn(&run_model_tests.step);
    all.dependOn(&run_frames.step);
    all.dependOn(&run_dispatch.step);
    all.dependOn(&run_qemu.step);
}

/// The native host test binary, with the hardware-independent kernel modules
/// it tests. `use_llvm` selects the LLVM backend (needed by kcov).
fn hostTests(b: *std.Build, filters: []const []const u8, use_llvm: bool) *std.Build.Step.Compile {
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/host/main.zig"),
            .target = b.graph.host,
            .optimize = .Debug,
        }),
        .filters = filters,
        .use_llvm = use_llvm,
    });
    inline for (.{
        .{ "vfs", "src/kernel/vfs.zig" },
        .{ "symbols", "src/kernel/debug/symbols.zig" },
        .{ "log_format", "src/kernel/debug/log_format.zig" },
        .{ "user_range", "src/kernel/user_range.zig" },
        .{ "elf_image", "src/kernel/elf_image.zig" },
        .{ "abi", "src/abi/linux.zig" },
        .{ "sysret", "src/arch/x86_64/sysret.zig" },
        .{ "fpu", "src/arch/x86_64/fpu.zig" },
        .{ "page_bitmap", "src/kernel/page_bitmap.zig" },
        .{ "raw_spinlock", "src/kernel/sync/raw_spinlock.zig" },
        .{ "lock_order", "src/kernel/sync/lock_order.zig" },
        .{ "random_core", "src/kernel/random_core.zig" },
        .{ "meltdown_rule", "src/arch/x86_64/meltdown_rule.zig" },
        .{ "timer_queue", "src/kernel/sync/timer_queue.zig" },
        .{ "startup_stack", "src/kernel/startup_stack.zig" },
        .{ "sh_words", "app/sh_words.zig" },
        .{ "vm_regions", "src/kernel/vm_regions.zig" },
        .{ "tar", "src/kernel/fs/tar.zig" },
        .{ "alloc", "app/alloc.zig" },
        .{ "ramfs", "src/kernel/fs/ramfs.zig" },
        .{ "tty_core", "src/kernel/tty_core.zig" },
        .{ "signal_frame", "src/kernel/signal_frame.zig" },
        .{ "ansi_core", "src/kernel/ansi_core.zig" },
        .{ "calendar", "src/kernel/calendar.zig" },
        .{ "cpuinfo", "src/kernel/cpuinfo.zig" },
    }) |m| {
        tests.root_module.addImport(m[0], b.createModule(.{
            .root_source_file = b.path(m[1]),
            .target = b.graph.host,
            .optimize = .Debug,
        }));
    }
    // Modules that use the ABI definitions import the same module the tests do.
    const imports = tests.root_module.import_table;
    imports.get("startup_stack").?.addImport("abi", imports.get("abi").?);
    return tests;
}

/// Kernel configuration exposed to the kernel as `build_options`.
const KernelOptions = struct {
    log_level: std.log.Level,
    assertions: bool,
    alloc_debug: bool,
    stack_usage: bool,
    poison: bool,
    bench: bool,
    allow_meltdown: bool,
    version: []const u8,
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
            // Position independent, so the bootloader can load the kernel at
            // a random address (KASLR): every reference inside the image is
            // relative to the instruction pointer.
            .red_zone = false,
            .pic = true,
            .sanitize_c = .off,
            // Keep RBP frame chains so panics and faults can print backtraces.
            .omit_frame_pointer = false,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    kernel.pie = true;
    kernel.entry = .{ .symbol_name = "kmain" };
    kernel.setLinkerScript(b.path("linker.ld"));
    // The vDSO (src/vdso): position independent, in one segment, with the
    // symbol versions and both hash tables glibc and Go look for; linked by
    // hand with Zig's lld for the options a library step does not offer.
    const vdso_obj = b.addObject(.{
        .name = "vdso",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/vdso/vdso.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .freestanding }),
            .optimize = .ReleaseSmall,
            .pic = true,
            .stack_check = false,
            .stack_protector = false,
            .strip = true,
        }),
    });
    const vdso_link = b.addSystemCommand(&.{ b.graph.zig_exe, "ld.lld", "-shared", "--hash-style=both", "--eh-frame-hdr", "-soname", "linux-vdso.so.1", "-z", "max-page-size=4096", "--no-undefined", "--build-id=none", "-T" });
    vdso_link.addFileArg(b.path("src/vdso/vdso.lds"));
    vdso_link.addArg("--version-script");
    vdso_link.addFileArg(b.path("src/vdso/vdso.map"));
    vdso_link.addArg("-o");
    const vdso_so = vdso_link.addOutputFileArg("vdso.so");
    vdso_link.addArtifactArg(vdso_obj);
    kernel.root_module.addAnonymousImport("vdso.so", .{ .root_source_file = vdso_so });

    const options = b.addOptions();
    options.addOption(bool, "is_test", is_test);
    options.addOption(std.log.Level, "log_level", kopts.log_level);
    options.addOption(bool, "assertions", kopts.assertions);
    options.addOption(bool, "alloc_debug", kopts.alloc_debug);
    // The test kernel always measures, so the tests cover it in every build
    // mode; unless it is built to be benchmarked (`-Dbench`).
    const test_extras = is_test and !kopts.bench;
    options.addOption(bool, "stack_usage", kopts.stack_usage or test_extras);
    options.addOption(bool, "poison", kopts.poison or test_extras);
    // Benchmarked kernels sample where the time goes (`profile.zig`).
    options.addOption(bool, "profile", kopts.bench);
    options.addOption(bool, "allow_meltdown", kopts.allow_meltdown);
    options.addOption([]const u8, "version", kopts.version);
    kernel.root_module.addOptions("build_options", options);
    // The user/kernel ABI, as a module of its own: the kernel's files that
    // are also tested on the host import it by name there too. Built like
    // the kernel itself (no red zone: interrupts use the same stack).
    kernel.root_module.addImport("abi", b.createModule(.{
        .root_source_file = b.path("src/abi/linux.zig"),
        .target = target,
        .optimize = optimize,
        .red_zone = false,
        .pic = true,
        .sanitize_c = .off,
        .omit_frame_pointer = false,
    }));
    return kernel;
}

/// Build the user program `name`.elf from `root`, linked at address `base`.
/// `sh` and `hello` get different bases so a debugger can load the symbols of
/// both at once (docs/debugging.md); the kernel accepts any address from
/// 64 KiB up to the region reserved for the user stack.
fn userProgram(
    b: *std.Build,
    name: []const u8,
    root: []const u8,
    base: u64,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = b.fmt("{s}.elf", .{name}),
        .root_module = b.createModule(.{
            .root_source_file = b.path(root),
            .target = target,
            .optimize = optimize,
            .pic = false,
            .sanitize_c = .off,
            // Debug builds keep symbols and DWARF so user programs can be
            // debugged under QEMU (docs/debugging.md); they are not loaded.
            .strip = optimize != .debug,
        }),
        .use_llvm = true,
        .use_lld = true,
    });
    exe.entry = .{ .symbol_name = "_start" };
    // app/linker.ld places the program at USER_BASE, defined here.
    const script = b.addWriteFiles().add(
        b.fmt("{s}.ld", .{name}),
        b.fmt("USER_BASE = 0x{x};\n{s}", .{ base, @embedFile("app/linker.ld") }),
    );
    exe.setLinkerScript(script);
    return exe;
}
