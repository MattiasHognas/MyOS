//! The few files of `/proc` a program reads about itself and the machine.
//!
//! They are text, made when the file is opened and kept with the open
//! file: reading is then reading a file, and what is read does not change
//! under the reader. Only the entries programs built for Linux were seen
//! to need are here (`docs/linux-programs.md`), in Linux's format, with
//! the fields nobody reads left at zero.
//!
//!   /proc/<pid>/maps     the mappings of the address space, one a line:
//!                        a C library finds the main thread's stack in it
//!   /proc/<pid>/stat     one line about the process (`ps` reads it)
//!   /proc/<pid>/cmdline  its arguments, each ending in a NUL
//!   /proc/<pid>/comm     its name, as `stat` gives it
//!   /proc/meminfo        memory in the machine and how much is free
//!   /proc/cpuinfo        each CPU, with its features (`cpuinfo.zig`)
//!
//! And the files of `/sys` that tell how many CPUs there are:
//!
//!   /sys/devices/system/cpu/online, possible, present    "0-3"
//!
//! `/proc/self` is the calling process's directory, and there is one for
//! every process by its ID; only the caller's own has `exe` and `maps`.

const std = @import("std");

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const proc = @import("process.zig");
const user_memory = @import("user_memory.zig");
const cpuinfo = @import("cpuinfo.zig");
const clock = @import("clock.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const percpu = @import("../arch/x86_64/percpu.zig");

pub const File = enum { maps, stat, cmdline, comm, meminfo, cpuinfo, cpus_online };

/// The generated file `name` names below `/proc/self` (or `/proc/<pid>`),
/// if `per_process`, or below `/proc`.
pub fn find(name: []const u8, per_process: bool) ?File {
    const table = if (per_process)
        &[_]struct { []const u8, File }{ .{ "maps", .maps }, .{ "stat", .stat }, .{ "cmdline", .cmdline }, .{ "comm", .comm } }
    else
        &[_]struct { []const u8, File }{ .{ "meminfo", .meminfo }, .{ "cpuinfo", .cpuinfo } };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// The directory that holds the CPU lists, and the lists in it.
pub const SYS_CPU_DIR = "/sys/devices/system/cpu";
pub const sys_cpu_files = [_][]const u8{ "online", "possible", "present" };
/// The directories above it, which list only the way down.
pub const sys_dirs = [_]struct { []const u8, []const u8 }{
    .{ "/sys", "devices" },
    .{ "/sys/devices", "system" },
    .{ "/sys/devices/system", "cpu" },
};

/// What the absolute `path` names below `/sys`: a directory, one of the
/// CPU lists, or nothing (null) if it is not below `/sys` at all.
pub fn findSys(path: []const u8) ?union(enum) { none, directory, file: File } {
    if (!std.mem.eql(u8, path, "/sys") and !std.mem.startsWith(u8, path, "/sys/")) return null;
    if (std.mem.eql(u8, path, SYS_CPU_DIR)) return .directory;
    for (sys_dirs) |d| if (std.mem.eql(u8, path, d[0])) return .directory;
    if (std.mem.startsWith(u8, path, SYS_CPU_DIR ++ "/")) {
        const name = path[SYS_CPU_DIR.len + 1 ..];
        for (sys_cpu_files) |f| if (std.mem.eql(u8, name, f)) return .{ .file = .cpus_online };
    }
    return .none;
}

/// The text of `file` for the process `p`, in memory the caller frees with
/// `heap.allocator`.
pub fn generate(file: File, p: *proc.Process) error{OutOfMemory}![]u8 {
    switch (file) {
        .maps => return user_memory.describe(p),
        .stat => {
            // pid (comm) state ppid pgrp session tty tpgid flags, four
            // fault counts, utime stime cutime cstime, priority nice
            // threads 0, starttime in clock ticks, vsize, rss in pages.
            const info = proc.describe(p);
            return std.fmt.allocPrint(heap.allocator, "{d} ({s}) {c} {d} {d} {d} 0 -1 0 0 0 0 0 0 0 0 0 20 0 {d} 0 {d} 0 {d}\n", .{
                p.pid,
                comm(p),
                info.state,
                info.ppid,
                info.pgid,
                info.sid,
                info.threads,
                p.start_ticks,
                p.pages,
            });
        },
        .cmdline => {
            const held = p.files_lock.acquire();
            defer p.files_lock.release(held);
            return heap.allocator.dupe(u8, p.cmdline);
        },
        .comm => return std.fmt.allocPrint(heap.allocator, "{s}\n", .{comm(p)}),
        .cpuinfo => {
            var leaves: cpuinfo.Leaves = .{};
            const l0 = cpu.cpuid(0, 0);
            leaves.l0 = .{ .eax = l0.eax, .ebx = l0.ebx, .ecx = l0.ecx, .edx = l0.edx };
            const l1 = cpu.cpuid(1, 0);
            leaves.l1 = .{ .eax = l1.eax, .ebx = l1.ebx, .ecx = l1.ecx, .edx = l1.edx };
            if (l0.eax >= 7) {
                const l7 = cpu.cpuid(7, 0);
                leaves.l7 = .{ .eax = l7.eax, .ebx = l7.ebx, .ecx = l7.ecx, .edx = l7.edx };
            }
            const top = cpu.cpuid(0x8000_0000, 0).eax;
            if (top >= 0x8000_0001) {
                const e1 = cpu.cpuid(0x8000_0001, 0);
                leaves.e1 = .{ .eax = e1.eax, .ebx = e1.ebx, .ecx = e1.ecx, .edx = e1.edx };
            }
            if (top >= 0x8000_0004) for (&leaves.brand, 0..) |*b, i| {
                const r = cpu.cpuid(0x8000_0002 + @as(u32, @intCast(i)), 0);
                b.* = .{ .eax = r.eax, .ebx = r.ebx, .ecx = r.ecx, .edx = r.edx };
            };
            const n = percpu.count();
            const cpus = try heap.allocator.alloc(cpuinfo.Cpu, n); // up to 256: not on the stack
            defer heap.allocator.free(cpus);
            for (cpus, 0..) |*c, i| c.* = .{ .number = @intCast(i), .apic_id = percpu.get(i).apic_id };
            return cpuinfo.format(heap.allocator, leaves, cpus, clock.tscHz());
        },
        .cpus_online => {
            var buf: [24]u8 = undefined;
            return heap.allocator.dupe(u8, cpuinfo.rangeList(&buf, percpu.count()));
        },
        .meminfo => {
            const total = pmm.totalPages() * pmm.PAGE_SIZE / 1024;
            const free = pmm.free_pages * pmm.PAGE_SIZE / 1024;
            return std.fmt.allocPrint(heap.allocator,
                \\MemTotal:       {d: >8} kB
                \\MemFree:        {d: >8} kB
                \\MemAvailable:   {d: >8} kB
                \\SwapTotal:             0 kB
                \\SwapFree:              0 kB
                \\
            , .{ total, free, free });
        },
    }
}

/// The name `stat` and `comm` give: the program file's name, at most 15
/// characters, as Linux keeps it.
fn comm(p: *const proc.Process) []const u8 {
    const base = if (std.mem.lastIndexOfScalar(u8, p.name, '/')) |i| p.name[i + 1 ..] else p.name;
    return base[0..@min(base.len, 15)];
}
