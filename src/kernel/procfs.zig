//! The few files of `/proc` a program reads about itself and the machine.
//!
//! They are text, made when the file is opened and kept with the open
//! file: reading is then reading a file, and what is read does not change
//! under the reader. Only the entries programs built for Linux were seen
//! to need are here (`docs/linux-programs.md`), in Linux's format, with
//! the fields nobody reads left at zero.
//!
//!   /proc/self/maps   the mappings of the address space, one a line: a C
//!                     library finds the main thread's stack in it
//!   /proc/self/stat   one line about the process; its start time is read
//!   /proc/meminfo     memory in the machine and how much is free
//!
//! `self` can also be the process's own ID. Other processes' entries do
//! not exist.

const std = @import("std");

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const proc = @import("process.zig");
const user_memory = @import("user_memory.zig");

pub const File = enum { maps, stat, meminfo };

/// The generated file `name` names below `/proc/self` (or `/proc/<pid>`),
/// if `per_process`, or below `/proc`.
pub fn find(name: []const u8, per_process: bool) ?File {
    const table = if (per_process)
        &[_]struct { []const u8, File }{ .{ "maps", .maps }, .{ "stat", .stat } }
    else
        &[_]struct { []const u8, File }{.{ "meminfo", .meminfo }};
    for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

/// The text of `file` for the process `p`, in memory the caller frees with
/// `heap.allocator`.
pub fn generate(file: File, p: *proc.Process) error{OutOfMemory}![]u8 {
    switch (file) {
        .maps => return user_memory.describe(p),
        .stat => {
            // pid (comm) state ppid pgrp session tty tpgid flags, four
            // fault counts, utime stime cutime cstime, priority nice
            // threads 0, starttime in clock ticks, then sizes nobody reads.
            const base = if (std.mem.lastIndexOfScalar(u8, p.name, '/')) |i| p.name[i + 1 ..] else p.name;
            const comm = base[0..@min(base.len, 15)];
            return std.fmt.allocPrint(heap.allocator, "{d} ({s}) R 0 {d} {d} 0 -1 0 0 0 0 0 0 0 0 0 20 0 {d} 0 {d} 0 0\n", .{
                p.pid,
                comm,
                p.pid,
                p.pid,
                p.thread_count,
                p.start_ticks,
            });
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
