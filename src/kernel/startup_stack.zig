//! The initial stack of a program, as Linux lays it out.
//!
//! A program built for Linux expects to find, at its first instruction:
//!
//!     rsp ->  argc
//!             argv[0] ... argv[argc-1], NULL
//!             envp[0] ... , NULL
//!             auxiliary vector: (key, value) pairs, ended by (AT_NULL, 0)
//!             ...
//!             the strings and data those point to
//!     top ->
//!
//! with `rsp` on a 16-byte boundary. The C library's startup code reads
//! all of it: the arguments and environment for `main`, and the auxiliary
//! vector to find its own program headers (for thread-local storage), the
//! page size and 16 random bytes.
//!
//! `build` writes that block into memory the caller will put at the top of
//! the new stack. No kernel dependencies: tested on the host.

const std = @import("std");
const abi = @import("abi");
const AT = abi.AT;

/// What goes on the stack.
pub const Args = struct {
    argv: []const []const u8,
    envp: []const []const u8,
    /// The path the program was started with (`AT_EXECFN`).
    execfn: []const u8,
    /// `AT_RANDOM`.
    random: [16]u8,
    /// Address of the program headers in the new address space, or 0 if
    /// they are not part of any loaded segment.
    phdr: u64,
    phent: u64,
    phnum: u64,
    entry: u64,
    /// CPUID.1:EDX.
    hwcap: u64,
    /// Timer ticks per second.
    clktck: u64,
};

pub const Error = error{
    /// The block does not fit in the memory given, or there are more
    /// strings than `abi.ARG_COUNT_MAX`.
    TooBig,
};

const platform = "x86_64";
const PAGE_SIZE = 4096;

/// Number of (key, value) pairs `build` writes, `AT_NULL` included.
const AUX_PAIRS = 18;

/// Number of 8-byte words in the vectors: argc, the two pointer arrays
/// with their terminators, and the auxiliary vector.
fn vectorWords(a: Args) usize {
    return 1 + a.argv.len + 1 + a.envp.len + 1 + 2 * AUX_PAIRS;
}

/// Bytes `build` needs for `a`, exactly.
pub fn size(a: Args) Error!usize {
    if (a.argv.len + a.envp.len > abi.ARG_COUNT_MAX) return error.TooBig;
    var strings: usize = a.execfn.len + 1 + platform.len + 1 + a.random.len;
    for (a.argv) |s| strings += s.len + 1;
    for (a.envp) |s| strings += s.len + 1;
    // The vectors end on a 16-byte boundary below the strings, and start
    // on one: an odd number of words gets one word of padding.
    const words = vectorWords(a);
    return std.mem.alignForward(usize, strings, 16) + (words + words % 2) * 8;
}

/// Write the block for `a` into the end of `mem`, which is the memory that
/// will be at the addresses below `top` in the new address space; `top`
/// is on a 16-byte boundary. Returns the stack pointer the program starts
/// with. Bytes of `mem` below that are left as they are.
pub fn build(mem: []u8, top: u64, a: Args) Error!u64 {
    std.debug.assert(top % 16 == 0);
    const need = try size(a);
    if (need > mem.len) return error.TooBig;
    const base = top - mem.len; // the address of mem[0]
    var at: usize = mem.len; // strings are written downwards from the top

    const execfn = pushString(mem, &at, base, a.execfn);
    const platform_addr = pushString(mem, &at, base, platform);
    at -= a.random.len;
    @memcpy(mem[at..][0..a.random.len], &a.random);
    const random = base + at;

    // The vectors start where the block starts. Each string's address
    // goes straight into its slot there as the string is written (keeping
    // them in an array first would take 2 KiB of kernel stack). Last
    // string first, so that the first argument has the lowest address, as
    // on Linux.
    const vectors = mem.len - need;
    const rsp = base + vectors;
    std.debug.assert(rsp % 16 == 0);
    const argv_slot = vectors + 8;
    const envp_slot = argv_slot + (a.argv.len + 1) * 8;
    var i = a.envp.len;
    while (i > 0) {
        i -= 1;
        putWord(mem, envp_slot + i * 8, pushString(mem, &at, base, a.envp[i]));
    }
    i = a.argv.len;
    while (i > 0) {
        i -= 1;
        putWord(mem, argv_slot + i * 8, pushString(mem, &at, base, a.argv[i]));
    }
    std.debug.assert(at >= envp_slot + (a.envp.len + 1) * 8); // the strings end above the vectors

    putWord(mem, vectors, a.argv.len);
    putWord(mem, argv_slot + a.argv.len * 8, 0);
    putWord(mem, envp_slot + a.envp.len * 8, 0);
    var w = Writer{ .mem = mem, .at = envp_slot + (a.envp.len + 1) * 8 };
    const aux = [AUX_PAIRS][2]u64{
        .{ AT.HWCAP, a.hwcap },
        .{ AT.PAGESZ, PAGE_SIZE },
        .{ AT.CLKTCK, a.clktck },
        .{ AT.PHDR, a.phdr },
        .{ AT.PHENT, a.phent },
        .{ AT.PHNUM, a.phnum },
        .{ AT.BASE, 0 },
        .{ AT.FLAGS, 0 },
        .{ AT.ENTRY, a.entry },
        .{ AT.UID, 0 },
        .{ AT.EUID, 0 },
        .{ AT.GID, 0 },
        .{ AT.EGID, 0 },
        .{ AT.SECURE, 0 },
        .{ AT.RANDOM, random },
        .{ AT.EXECFN, execfn },
        .{ AT.PLATFORM, platform_addr },
        .{ AT.NULL, 0 },
    };
    for (aux) |pair| {
        w.word(pair[0]);
        w.word(pair[1]);
    }
    return rsp;
}

/// Copy `s` and a terminating NUL to just below `at`, move `at` down, and
/// return the address the string has in the new address space.
fn pushString(mem: []u8, at: *usize, base: u64, s: []const u8) u64 {
    at.* -= s.len + 1;
    @memcpy(mem[at.*..][0..s.len], s);
    mem[at.* + s.len] = 0;
    return base + at.*;
}

fn putWord(mem: []u8, at: usize, value: u64) void {
    std.mem.writeInt(u64, mem[at..][0..8], value, .little);
}

const Writer = struct {
    mem: []u8,
    at: usize,

    fn word(self: *Writer, value: u64) void {
        std.mem.writeInt(u64, self.mem[self.at..][0..8], value, .little);
        self.at += 8;
    }
};
