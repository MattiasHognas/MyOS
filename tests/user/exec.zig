//! `/test/exec`: `execve` as Linux programs use it. A child made with
//! `fork` or `vfork` runs this program again in another mode, which
//! checks what it got: its arguments and environment, its process ID,
//! descriptors marked close-on-exec closed and the others open, signal
//! handlers back to the default and ignored signals still ignored. A
//! failed `execve` leaves the program running; a `#!` script runs its
//! interpreter; a process with several threads keeps only the one that
//! calls it. Exits with 0, or with the number of the first failing check
//! (the modes the children run in exit with their own codes).

const std = @import("std");

const lib = @import("lib");
pub const panic = lib.panic;
comptime {
    _ = lib; // its `_start` calls `main`
}
const abi = lib.abi;
const Sys = lib.Sys;

fn expect(ok: bool, check: u64) void {
    if (!ok) _ = lib.syscall(Sys.exit_group, check, 0, 0);
}

fn eql(s: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(s), want);
}

fn wait4(pid: u64, status: *i32) u64 {
    return lib.syscall6(Sys.wait4, pid, @intFromPtr(status), 0, 0, 0, 0);
}

fn exitCode(status: i32) i32 {
    return if (status & 0x7F == 0) (status >> 8) & 0xFF else -1;
}

fn execve(path: [*:0]const u8, argv: []const ?[*:0]const u8, envp: []const ?[*:0]const u8) u64 {
    return lib.syscall(Sys.execve, @intFromPtr(path), @intFromPtr(argv.ptr), @intFromPtr(envp.ptr));
}

/// Decimal text of `n` in `buf`, NUL-terminated.
fn decimal(buf: []u8, n: u64) [*:0]const u8 {
    var tmp: [20]u8 = undefined;
    var i: usize = tmp.len;
    var v = n;
    while (true) {
        i -= 1;
        tmp[i] = @intCast('0' + v % 10);
        v /= 10;
        if (v == 0) break;
    }
    const len = tmp.len - i;
    @memcpy(buf[0..len], tmp[i..]);
    buf[len] = 0;
    return @ptrCast(buf.ptr);
}

fn parse(s: [*:0]const u8) u64 {
    var n: u64 = 0;
    var i: usize = 0;
    while (s[i] != 0) : (i += 1) n = n * 10 + (s[i] - '0');
    return n;
}

fn restorer() callconv(.naked) void {
    asm volatile ("mov $15, %eax\nsyscall");
}
fn onUsr1(_: i32) callconv(.c) void {}

fn sigaction(sig: u64, handler: u64) void {
    const act = abi.SigAction{ .handler = handler, .flags = 0x0400_0000, .restorer = @intFromPtr(&restorer) };
    _ = lib.syscall6(Sys.rt_sigaction, sig, @intFromPtr(&act), 0, abi.SIGSET_SIZE, 0, 0);
}

fn handlerOf(sig: u64) u64 {
    var old: abi.SigAction = .{};
    _ = lib.syscall6(Sys.rt_sigaction, sig, 0, @intFromPtr(&old), abi.SIGSET_SIZE, 0, 0);
    return old.handler;
}

/// The child's side: argv[1] says what to check.
fn child(args: []const [*:0]const u8) noreturn {
    const mode = args[1];
    if (eql(mode, "checks")) {
        // argv: exec checks <pid> <kept fd> <closed fd> "two words"
        if (args.len != 6 or !eql(args[5], "two words")) lib.exit(60);
        if (lib.syscall(Sys.getpid, 0, 0, 0) != parse(args[2])) lib.exit(61);
        const env = lib.environ();
        if (env.len != 2 or !eql(env[0], "A=1") or !eql(env[1], "B=two")) lib.exit(62);
        if (lib.syscall(Sys.fcntl, parse(args[3]), 1, 0) != 0) lib.exit(63); // kept, flag off
        if (lib.syscall(Sys.fcntl, parse(args[4]), 1, 0) != lib.err(.BADF)) lib.exit(64); // closed
        if (handlerOf(10) != 0) lib.exit(65); // SIGUSR1: the handler is gone
        if (handlerOf(12) != 1) lib.exit(66); // SIGUSR2: still ignored
        // A fresh program: FS base 0, the memory of the old one gone.
        var fs: u64 = 1;
        _ = lib.syscall(Sys.arch_prctl, abi.ARCH.GET_FS, @intFromPtr(&fs), 0);
        if (fs != 0) lib.exit(67);
        lib.exit(42);
    }
    if (eql(mode, "plain")) lib.exit(43);
    if (eql(mode, "scriptarg")) {
        // From `#!/test/exec scriptarg`: the interpreter, its argument,
        // the script, then the caller's arguments from the second.
        if (args.len != 4 or !eql(args[0], "/test/exec") or !std.mem.startsWith(u8, std.mem.span(args[2]), "/tmp/exec-script-") or !eql(args[3], "more")) lib.exit(70);
        lib.exit(44);
    }
    if (eql(mode, "threads")) lib.exit(45);
    lib.exit(99);
}

var spin_stack: [8192]u8 align(16) = undefined;

pub fn main() noreturn {
    const args = lib.argv();
    if (args.len > 1) child(args);

    var status: i32 = 0;
    // --- A failed execve leaves this program running.
    expect(execve("/does/not/exist", &.{ "x", null }, &.{null}) == lib.err(.NOENT), 1);
    expect(execve("/etc/motd", &.{ "x", null }, &.{null}) == lib.err(.NOEXEC), 2);
    expect(lib.syscall(Sys.execve, @intFromPtr("/test/exec"), 8, 0) == lib.err(.FAULT), 3);

    // --- fork, then execve with arguments, environment, descriptors,
    // signal actions.
    var pfd: [2]i32 = undefined;
    expect(lib.syscall(Sys.pipe2, @intFromPtr(&pfd), 0, 0) == 0, 4);
    expect(lib.syscall(Sys.fcntl, @intCast(pfd[1]), 2, 1) == 0, 5); // FD_CLOEXEC on the write end
    sigaction(10, @intFromPtr(&onUsr1));
    sigaction(12, 1); // SIG_IGN
    const pid = lib.syscall(Sys.fork, 0, 0, 0);
    if (pid == 0) {
        var pid_buf: [24]u8 = undefined;
        var kept_buf: [24]u8 = undefined;
        var closed_buf: [24]u8 = undefined;
        const me = lib.syscall(Sys.getpid, 0, 0, 0);
        const r = execve("/test/exec", &.{ "exec", "checks", decimal(&pid_buf, me), decimal(&kept_buf, @intCast(pfd[0])), decimal(&closed_buf, @intCast(pfd[1])), "two words", null }, &.{ "A=1", "B=two", null });
        lib.exit(@intCast(100 + (~r +% 1) % 100)); // execve failed
    }
    expect(wait4(pid, &status) == pid, 6);
    expect(exitCode(status) == 42, 7);

    // --- vfork and execve: the parent goes on once the child runs its
    // new program.
    const vpid = lib.syscall(Sys.vfork, 0, 0, 0);
    if (vpid == 0) {
        _ = execve("/test/exec", &.{ "exec", "plain", null }, &.{null});
        _ = lib.syscall(Sys.exit, 101, 0, 0);
    }
    expect(wait4(vpid, &status) == vpid and exitCode(status) == 43, 8);

    // --- A script: `#!` names the interpreter. (A name of its own: two of
    // these programs may run at once.)
    var script_name: [48]u8 = undefined;
    const prefix = "/tmp/exec-script-";
    @memcpy(script_name[0..prefix.len], prefix);
    _ = decimal(script_name[prefix.len..], lib.syscall(Sys.getpid, 0, 0, 0));
    const script_path: [*:0]const u8 = @ptrCast(&script_name);
    const script = lib.syscall6(Sys.openat, @bitCast(@as(i64, abi.AT_FDCWD)), @intFromPtr(script_path), abi.O.WRONLY | abi.O.CREAT | abi.O.TRUNC, 0o755, 0, 0);
    expect(!lib.isError(script), 9);
    const text = "#!/test/exec scriptarg\nanything\n";
    expect(lib.syscall(Sys.write, script, @intFromPtr(text), text.len) == text.len, 10);
    _ = lib.close(script);
    const spid = lib.syscall(Sys.fork, 0, 0, 0);
    if (spid == 0) {
        _ = execve(script_path, &.{ "exec-script", "more", null }, &.{null});
        lib.exit(102);
    }
    expect(wait4(spid, &status) == spid and exitCode(status) == 44, 11);
    _ = lib.syscall(Sys.unlink, @intFromPtr(script_path), 0, 0);

    // --- execve from a process with another thread: that one ends.
    const tpid = lib.syscall(Sys.fork, 0, 0, 0);
    if (tpid == 0) {
        const flags = 0x100 | 0x200 | 0x400 | 0x800 | 0x10000; // a thread
        const top = @intFromPtr(&spin_stack) + spin_stack.len;
        const t = asm volatile (
            \\ mov $56, %%eax
            \\ syscall
            \\ test %%rax, %%rax
            \\ jnz 1f
            \\2:
            \\ pause
            \\ jmp 2b
            \\1:
            : [ret] "={rax}" (-> u64),
            : [flags] "{rdi}" (@as(u64, flags)),
              [stack] "{rsi}" (top),
              [ptid] "{rdx}" (@as(u64, 0)),
              [ctid] "{r10}" (@as(u64, 0)),
              [tls] "{r8}" (@as(u64, 0)),
            : .{ .rcx = true, .r11 = true, .memory = true });
        if (lib.isError(t)) lib.exit(103);
        _ = execve("/test/exec", &.{ "exec", "threads", null }, &.{null});
        lib.exit(104);
    }
    expect(wait4(tpid, &status) == tpid and exitCode(status) == 45, 12);

    _ = lib.close(@intCast(pfd[0]));
    _ = lib.close(@intCast(pfd[1]));
    lib.exit(0);
}
