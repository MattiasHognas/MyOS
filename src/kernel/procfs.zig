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
//!
//! `/proc/self` is the calling process's directory, and there is one for
//! every process by its ID; only the caller's own has `exe` and `maps`.

const std = @import("std");

const heap = @import("heap.zig");
const pmm = @import("pmm.zig");
const proc = @import("process.zig");
const user_memory = @import("user_memory.zig");

pub const File = enum { maps, stat, cmdline, comm, meminfo };

/// The generated file `name` names below `/proc/self` (or `/proc/<pid>`),
/// if `per_process`, or below `/proc`.
pub fn find(name: []const u8, per_process: bool) ?File {
    const table = if (per_process)
        &[_]struct { []const u8, File }{ .{ "maps", .maps }, .{ "stat", .stat }, .{ "cmdline", .cmdline }, .{ "comm", .comm } }
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
