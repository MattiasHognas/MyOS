//! `bench`: the core operations of a kernel, timed the same way on Linux
//! and on MyOS. One static program for x86_64-linux with no C library,
//! so that both kernels run exactly the same instructions; `run.sh` runs
//! it in a Linux guest and a MyOS guest under the same QEMU and KVM.
//!
//! Each benchmark repeats an operation for about `RUN_NS`, `RUNS` times,
//! and reports nanoseconds per operation: the median, the fastest and the
//! slowest of the runs. Some also run as 1, 2, 4, ... copies at once
//! (threads of one process, will-it-scale's shape), up to the CPUs there
//! are, and report the time per operation of one copy: flat is perfect
//! scaling.
//!
//! Output is CSV on standard output, ending with `BENCH_DONE`:
//!
//!     bench,<name>,<copies>,<median ns>,<min ns>,<max ns>
//!
//! Then it runs the .NET workload of `tools/bench/dotnet` if the image has
//! it (`/dotnet-bench` or `/usr/bin/dotnet-bench`), which prints lines of
//! the same form.
//!
//! Run as process 1 (the Linux guest's `/init`), it mounts `devtmpfs` for
//! a console, and `/proc`, `/sys` and `/tmp`, first, and powers the
//! machine off at the end.

const std = @import("std");
const linux = std.os.linux;

const RUNS = 5;
const RUN_NS: u64 = 150 * std.time.ns_per_ms;
const MAX_COPIES = 8;
const PAGE = 4096;

// ---------------------------------------------------------------------------
// Output and time.

var out_buf: [256]u8 = undefined;

fn print(comptime fmt: []const u8, args: anytype) void {
    const text = std.fmt.bufPrint(&out_buf, fmt, args) catch return;
    var done: usize = 0;
    while (done < text.len) {
        const rc = linux.write(1, text[done..].ptr, text.len - done);
        if (linux.errno(rc) != .SUCCESS) return;
        done += rc;
    }
}

/// The monotonic clock through a real system call, so that measuring does
/// not depend on whether there is a vDSO.
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.syscall2(.clock_gettime, @intFromEnum(linux.CLOCK.MONOTONIC), @intFromPtr(&ts));
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn fail(comptime what: []const u8) noreturn {
    print("bench,error," ++ what ++ "\n", .{});
    exit(1);
}

fn exit(code: u8) noreturn {
    if (linux.getpid() == 1) {
        print("BENCH_DONE\n", .{});
        _ = linux.reboot(.MAGIC1, .MAGIC2, .POWER_OFF, null);
    }
    linux.exit_group(code);
}

// ---------------------------------------------------------------------------
// Running a benchmark.

/// An operation, done `n` times per call; returns false on failure.
const Op = *const fn (n: u64) bool;

/// ns per operation of one run of `op`: grow the count until a run takes
/// `RUN_NS`.
fn timeRun(op: Op) f64 {
    var n: u64 = 1;
    while (true) {
        const start = now();
        if (!op(n)) fail("operation failed");
        const took = now() - start;
        if (took >= RUN_NS) return @as(f64, @floatFromInt(took)) / @as(f64, @floatFromInt(n));
        // Aim at RUN_NS from what this took, at least doubling.
        const want = if (took == 0) n * 16 else @max(n * 2, n * RUN_NS / took + 1);
        n = @min(want, n * 64);
    }
}

fn report(name: []const u8, copies: usize, samples: []f64) void {
    std.mem.sort(f64, samples, {}, std.sort.asc(f64));
    print("bench,{s},{d},{d:.1},{d:.1},{d:.1}\n", .{ name, copies, samples[samples.len / 2], samples[0], samples[samples.len - 1] });
}

fn bench(name: []const u8, op: Op) void {
    _ = timeRun(op); // warm up
    var samples: [RUNS]f64 = undefined;
    for (&samples) |*s| s.* = timeRun(op);
    report(name, 1, &samples);
}

/// `op` on `copies` threads at once, each for about `RUN_NS`; the time
/// per operation of one copy.
fn benchCopies(name: []const u8, op: Op, copies: usize) void {
    var samples: [RUNS]f64 = undefined;
    for (0..RUNS + 1) |r| {
        var results: [MAX_COPIES]f64 = undefined;
        var threads: [MAX_COPIES]std.Thread = undefined;
        for (0..copies) |i| {
            threads[i] = std.Thread.spawn(.{ .stack_size = 256 * 1024 }, copyMain, .{ op, &results[i] }) catch fail("thread");
        }
        var sum: f64 = 0;
        for (0..copies) |i| {
            threads[i].join();
            sum += results[i];
        }
        if (r > 0) samples[r - 1] = sum / @as(f64, @floatFromInt(copies)); // the first is the warm-up
    }
    report(name, copies, &samples);
}

fn copyMain(op: Op, result: *f64) void {
    result.* = timeRun(op);
}

// ---------------------------------------------------------------------------
// The operations.

/// The cheapest system call there is.
fn opGetppid(n: u64) bool {
    for (0..n) |_| _ = linux.syscall0(.getppid);
    return true;
}

/// `clock_gettime` as the C library and Go's runtime make it: through the
/// vDSO where the kernel has one.
fn opClockVdso(n: u64) bool {
    var ts: linux.timespec = undefined;
    for (0..n) |_| _ = linux.clock_gettime(.MONOTONIC, &ts);
    return true;
}

/// `clock_gettime` as a system call.
fn opClockSyscall(n: u64) bool {
    var ts: linux.timespec = undefined;
    for (0..n) |_| _ = linux.syscall2(.clock_gettime, @intFromEnum(linux.CLOCK.MONOTONIC), @intFromPtr(&ts));
    return true;
}

/// A round trip of one byte to another process and back through two
/// pipes: two context switches between address spaces.
fn opPipePingPong(n: u64) bool {
    var to: [2]i32 = undefined;
    var back: [2]i32 = undefined;
    if (linux.errno(linux.pipe2(&to, .{})) != .SUCCESS) return false;
    if (linux.errno(linux.pipe2(&back, .{})) != .SUCCESS) return false;
    defer for ([_]i32{ to[0], to[1], back[0], back[1] }) |fd| {
        _ = linux.close(fd);
    };
    const pid = linux.fork();
    if (linux.errno(pid) != .SUCCESS) return false;
    var b: [1]u8 = .{0};
    if (pid == 0) {
        while (true) {
            if (linux.read(to[0], &b, 1) != 1) linux.exit_group(0);
            if (b[0] == 1) linux.exit_group(0);
            _ = linux.write(back[1], &b, 1);
        }
    }
    for (0..n) |_| {
        if (linux.write(to[1], &b, 1) != 1) return false;
        if (linux.read(back[0], &b, 1) != 1) return false;
    }
    b[0] = 1;
    _ = linux.write(to[1], &b, 1);
    var status: i32 = 0;
    _ = linux.wait4(@intCast(pid), &status, 0, null);
    return true;
}

/// Two threads handing a turn back and forth through a futex: a wake-up
/// and a switch between threads of one address space, each way.
var futex_word: std.atomic.Value(u32) = .init(0);
var futex_rounds: u64 = 0;

fn futexWait(expect: u32) void {
    while (futex_word.load(.acquire) == expect) {
        _ = linux.futex_4arg(&futex_word.raw, .{ .cmd = .WAIT, .private = true }, expect, null);
    }
}

fn futexSet(v: u32) void {
    futex_word.store(v, .release);
    _ = linux.futex_3arg(&futex_word.raw, .{ .cmd = .WAKE, .private = true }, 1);
}

fn futexPartner() void {
    for (0..futex_rounds) |_| {
        futexWait(0); // until it is this thread's turn (1)
        futexSet(0);
    }
}

fn opFutexPingPong(n: u64) bool {
    futex_word.store(0, .release);
    futex_rounds = n;
    const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, futexPartner, .{}) catch return false;
    for (0..n) |_| {
        futexSet(1);
        futexWait(1);
    }
    t.join();
    return true;
}

/// First touches of fresh anonymous memory, a page each: the page-fault
/// path. Reported per page.
const FAULT_PAGES = 1024;

fn opPageFault(n: u64) bool {
    const len = FAULT_PAGES * PAGE;
    var done: u64 = 0;
    while (done < n) {
        const addr = linux.mmap(null, len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (linux.errno(addr) != .SUCCESS) return false;
        const pages = @min(FAULT_PAGES, n - done);
        var i: usize = 0;
        while (i < pages) : (i += 1) @as(*volatile u8, @ptrFromInt(addr + i * PAGE)).* = 1;
        _ = linux.munmap(@ptrFromInt(addr), len);
        done += pages;
    }
    return true;
}

/// A page mapped, touched and unmapped: the mapping calls and a fault.
fn opMmapChurn(n: u64) bool {
    for (0..n) |_| {
        const addr = linux.mmap(null, PAGE, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        if (linux.errno(addr) != .SUCCESS) return false;
        @as(*volatile u8, @ptrFromInt(addr)).* = 1;
        _ = linux.munmap(@ptrFromInt(addr), PAGE);
    }
    return true;
}

fn nothing() void {}

/// A thread started and joined.
fn opThreadCreate(n: u64) bool {
    for (0..n) |_| {
        const t = std.Thread.spawn(.{ .stack_size = 64 * 1024 }, nothing, .{}) catch return false;
        t.join();
    }
    return true;
}

/// A process forked, ended and collected.
fn opForkWait(n: u64) bool {
    for (0..n) |_| {
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return false;
        if (pid == 0) linux.exit_group(0);
        var status: i32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
    }
    return true;
}

// ---------------------------------------------------------------------------

/// The CPUs this process may run on.
fn cpuCount() usize {
    var mask: [128]u8 = @splat(0);
    const rc = linux.syscall3(.sched_getaffinity, 0, mask.len, @intFromPtr(&mask));
    if (linux.errno(rc) != .SUCCESS) return 1;
    var n: usize = 0;
    for (mask[0..rc]) |byte| n += @popCount(byte);
    return @max(n, 1);
}

/// As process 1 there is no console yet: mount devtmpfs and open one; and
/// /proc and /sys, which MyOS has and the .NET runtime reads.
fn becomeConsole() void {
    _ = linux.mkdir("/dev", 0o755);
    _ = linux.mount("devtmpfs", "/dev", "devtmpfs", 0, 0);
    _ = linux.mkdir("/proc", 0o555);
    _ = linux.mount("proc", "/proc", "proc", 0, 0);
    _ = linux.mkdir("/sys", 0o555);
    _ = linux.mount("sysfs", "/sys", "sysfs", 0, 0);
    _ = linux.mkdir("/tmp", 0o1777);
    _ = linux.mount("tmpfs", "/tmp", "tmpfs", 0, 0);
    const fd = linux.open("/dev/console", .{ .ACCMODE = .RDWR }, 0);
    if (linux.errno(fd) != .SUCCESS) return;
    for ([_]i32{ 0, 1, 2 }) |want| _ = linux.dup2(@intCast(fd), want);
}

pub fn main() void {
    if (linux.getpid() == 1) becomeConsole();
    var uts: linux.utsname = undefined;
    _ = linux.uname(&uts);
    const cpus = cpuCount();
    print("bench,kernel,{s} {s},cpus {d}\n", .{ std.mem.sliceTo(&uts.sysname, 0), std.mem.sliceTo(&uts.release, 0), cpus });

    bench("getppid", opGetppid);
    bench("clock_gettime", opClockVdso);
    bench("clock_gettime_syscall", opClockSyscall);
    bench("pipe_pingpong", opPipePingPong);
    bench("futex_pingpong", opFutexPingPong);
    bench("page_fault", opPageFault);
    bench("mmap_churn", opMmapChurn);
    bench("thread_create", opThreadCreate);
    bench("fork_wait", opForkWait);

    // Several copies at once: what the kernel's locks and caches do with
    // threads of one process on several CPUs.
    var copies: usize = 2;
    while (copies <= @min(cpus, MAX_COPIES)) : (copies *= 2) {
        benchCopies("getppid", opGetppid, copies);
        benchCopies("page_fault", opPageFault, copies);
        benchCopies("mmap_churn", opMmapChurn, copies);
    }
    runDotnet();
    print("BENCH_DONE\n", .{});
    exit(0);
}

/// The .NET workload (`tools/bench/dotnet`), where the image has it: it
/// prints its own lines.
fn runDotnet() void {
    for ([_][*:0]const u8{ "/dotnet-bench", "/usr/bin/dotnet-bench" }) |path| {
        if (linux.errno(linux.access(path, 1)) != .SUCCESS) continue;
        const pid = linux.fork();
        if (linux.errno(pid) != .SUCCESS) return;
        if (pid == 0) {
            const argv = [_:null]?[*:0]const u8{path};
            const envp = [_:null]?[*:0]const u8{ "HOME=/", "TMPDIR=/tmp" };
            _ = linux.execve(path, &argv, &envp);
            linux.exit_group(127);
        }
        var status: i32 = 0;
        _ = linux.wait4(@intCast(pid), &status, 0, null);
        if (status != 0) print("bench,error,dotnet-bench status {d}\n", .{status});
        return;
    }
}
