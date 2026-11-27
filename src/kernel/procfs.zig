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
//!   /proc/syscalls, /proc/lockstat, /proc/<pid>/schedstat
//!                        the always-on counters (`stats.zig`)
//!
//!   /proc/<pid>/mountinfo  the filesystems, as Linux lists them
//!   /proc/<pid>/cgroup     "0::/": the one control group, at the root
//!
//! And the files of `/sys` that tell how many CPUs there are and what a
//! process may use:
//!
//!   /sys/devices/system/cpu/online, possible, present    "0-3"
//!   /sys/fs/cgroup/memory.max, memory.current, memory.stat, cpu.max,
//!       cpuset.cpus.effective, cgroup.controllers
//!
//! There are no control groups; the files at `/sys/fs/cgroup` say what
//! the reader's own limits are in the form of the one at the root of a
//! control-group (v2) hierarchy, which is what runtimes read to size
//! themselves (.NET's collector its heap, Go its threads): `memory.max`
//! is the reader's memory limit, `memory.current` what it uses.
//!
//! `/proc/self` is the calling process's directory, and there is one for
//! every process by its ID; only the caller's own has `exe` and `maps`.

const std = @import("std");

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const proc = @import("process.zig");
const user_memory = @import("user_memory.zig");
const cpuinfo = @import("cpuinfo.zig");
const stats = @import("stats.zig");
const clock = @import("clock.zig");
const cpu = @import("../arch/x86_64/cpu.zig");
const percpu = @import("../arch/x86_64/percpu.zig");

pub const File = enum {
    maps,
    stat,
    cmdline,
    comm,
    mountinfo,
    cgroup,
    schedstat,
    meminfo,
    syscalls,
    lockstat,
    profile,
    cpuinfo,
    cpus_online,
    cg_controllers,
    cg_memory_max,
    cg_memory_current,
    cg_memory_stat,
    cg_cpu_max,
    cg_cpuset,
};

/// The generated file `name` names below `/proc/self` (or `/proc/<pid>`),
/// if `per_process`, or below `/proc`.
pub fn find(name: []const u8, per_process: bool) ?File {
    const table = if (per_process)
        &[_]struct { []const u8, File }{ .{ "maps", .maps }, .{ "stat", .stat }, .{ "cmdline", .cmdline }, .{ "comm", .comm }, .{ "mountinfo", .mountinfo }, .{ "cgroup", .cgroup }, .{ "schedstat", .schedstat } }
    else
        &[_]struct { []const u8, File }{ .{ "meminfo", .meminfo }, .{ "cpuinfo", .cpuinfo }, .{ "syscalls", .syscalls }, .{ "lockstat", .lockstat }, .{ "profile", .profile } };
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// Everything there is below `/sys`: directories, and the generated
/// files in them. A directory lists the entries whose parent it is.
pub const SysEntry = struct { path: []const u8, file: ?File = null };
pub const sys_tree = [_]SysEntry{
    .{ .path = "/sys" },
    .{ .path = "/sys/devices" },
    .{ .path = "/sys/devices/system" },
    .{ .path = "/sys/devices/system/cpu" },
    .{ .path = "/sys/devices/system/cpu/online", .file = .cpus_online },
    .{ .path = "/sys/devices/system/cpu/possible", .file = .cpus_online },
    .{ .path = "/sys/devices/system/cpu/present", .file = .cpus_online },
    .{ .path = "/sys/fs" },
    .{ .path = "/sys/fs/cgroup" },
    .{ .path = "/sys/fs/cgroup/cgroup.controllers", .file = .cg_controllers },
    .{ .path = "/sys/fs/cgroup/cpu.max", .file = .cg_cpu_max },
    .{ .path = "/sys/fs/cgroup/cpuset.cpus.effective", .file = .cg_cpuset },
    .{ .path = "/sys/fs/cgroup/memory.current", .file = .cg_memory_current },
    .{ .path = "/sys/fs/cgroup/memory.max", .file = .cg_memory_max },
    .{ .path = "/sys/fs/cgroup/memory.stat", .file = .cg_memory_stat },
};

/// What the absolute `path` names below `/sys`: a directory, one of the
/// generated files, or nothing (null) if it is not below `/sys` at all.
pub fn findSys(path: []const u8) ?union(enum) { none, directory, file: File } {
    if (!std.mem.eql(u8, path, "/sys") and !std.mem.startsWith(u8, path, "/sys/")) return null;
    for (sys_tree) |e| {
        if (!std.mem.eql(u8, path, e.path)) continue;
        return if (e.file) |f| .{ .file = f } else .directory;
    }
    return .none;
}

/// The filesystem `statfs` reports `path` (absolute) to be on, by its
/// magic number: Linux's for `/proc`, `/sys` and the control groups; the
/// one in memory for everything else.
pub fn fsMagic(path: []const u8) i64 {
    const under = struct {
        fn f(p: []const u8, dir: []const u8) bool {
            return std.mem.eql(u8, p, dir) or (std.mem.startsWith(u8, p, dir) and p.len > dir.len and p[dir.len] == '/');
        }
    }.f;
    if (under(path, "/sys/fs/cgroup")) return 0x63677270; // CGROUP2_SUPER_MAGIC
    if (under(path, "/sys")) return 0x62656572; // SYSFS_MAGIC
    if (under(path, "/proc")) return 0x9fa0; // PROC_SUPER_MAGIC
    return 0x01021994; // TMPFS_MAGIC
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
        .cpus_online, .cg_cpuset => {
            var buf: [24]u8 = undefined;
            return heap.allocator.dupe(u8, cpuinfo.rangeList(&buf, percpu.count()));
        },
        .mountinfo => return heap.allocator.dupe(u8,
            \\1 0 0:1 / / ro,relatime - tarfs initrd ro
            \\2 1 0:2 / /tmp rw,relatime - tmpfs tmpfs rw
            \\3 1 0:3 / /proc rw,relatime - proc proc rw
            \\4 1 0:4 / /sys ro,relatime - sysfs sysfs ro
            \\5 4 0:5 / /sys/fs/cgroup ro,relatime - cgroup2 cgroup2 ro
            \\6 1 0:6 / /dev rw,relatime - devtmpfs devtmpfs rw
            \\
        ),
        .cgroup => return heap.allocator.dupe(u8, "0::/\n"),
        .schedstat => {
            const t = proc.schedTotals(p);
            return std.fmt.allocPrint(heap.allocator, "{d} {d} {d}\n", .{ stats.toNs(t.run), stats.toNs(t.wait), t.slices });
        },
        .syscalls => return stats.syscallReport(heap.allocator),
        .lockstat => return stats.lockReport(heap.allocator),
        .profile => return @import("profile.zig").report(heap.allocator),
        .cg_controllers => return heap.allocator.dupe(u8, "cpuset cpu memory\n"),
        .cg_cpu_max => return heap.allocator.dupe(u8, "max 100000\n"),
        .cg_memory_max => {
            const limit = p.limits.max_pages;
            if (limit == proc.Limits.UNLIMITED) return heap.allocator.dupe(u8, "max\n");
            return std.fmt.allocPrint(heap.allocator, "{d}\n", .{limit *| pmm.PAGE_SIZE});
        },
        .cg_memory_current => return std.fmt.allocPrint(heap.allocator, "{d}\n", .{p.pages * pmm.PAGE_SIZE}),
        .cg_memory_stat => return std.fmt.allocPrint(heap.allocator,
            \\anon {d}
            \\file 0
            \\kernel 0
            \\shmem 0
            \\file_mapped 0
            \\active_anon {d}
            \\inactive_anon 0
            \\active_file 0
            \\inactive_file 0
            \\
        , .{ p.pages * pmm.PAGE_SIZE, p.pages * pmm.PAGE_SIZE }),
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
