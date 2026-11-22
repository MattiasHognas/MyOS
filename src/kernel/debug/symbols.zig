//! Symbol lookup in an ELF64 `.symtab`, used to turn code addresses into
//! function names for backtraces.
//!
//! Pure code with no kernel dependencies, so it is also unit tested on the
//! host. Every offset read from the image is bounds checked: a malformed image
//! makes `Table.init` return null instead of reading out of bounds.

const std = @import("std");

/// ELF section type of the static symbol table.
const SHT_SYMTAB = 2;
/// ELF symbol types that can name code.
const STT_NOTYPE = 0;
const STT_FUNC = 2;
/// Size of one `Elf64_Sym` entry.
const SYM_SIZE = 24;
/// Size of one `Elf64_Shdr` entry.
const SHDR_SIZE = 64;
/// How far past a symbol without a size (e.g. an assembly label) an address
/// may lie and still be attributed to it.
const UNSIZED_RANGE = 0x1000;

/// A symbolized address: the containing symbol's name and the offset into it.
pub const Symbol = struct {
    name: []const u8,
    offset: u64,
};

/// The symbol and string tables of an ELF image.
pub const Table = struct {
    symtab: []const u8,
    strtab: []const u8,

    /// Locate `.symtab` and its string table in the ELF64 image `elf`.
    /// Returns null if the image is not a little-endian ELF64 file, has no
    /// symbol table (e.g. it was stripped), or any header points outside it.
    pub fn init(elf: []const u8) ?Table {
        if (elf.len < 64 or !std.mem.eql(u8, elf[0..4], "\x7fELF")) return null;
        if (elf[4] != 2 or elf[5] != 1) return null; // ELF64, little endian

        const shoff = r64(elf, 0x28);
        const shentsize = r16(elf, 0x3A);
        const shnum = r16(elf, 0x3C);
        if (shentsize != SHDR_SIZE) return null;
        const shdrs = slice(elf, shoff, @as(u64, shnum) * SHDR_SIZE) orelse return null;

        for (0..shnum) |i| {
            const sh = shdrs[i * SHDR_SIZE ..][0..SHDR_SIZE];
            if (r32(sh, 4) != SHT_SYMTAB) continue;
            const symtab = slice(elf, r64(sh, 24), r64(sh, 32)) orelse return null;
            const link = r32(sh, 40);
            if (link >= shnum) return null;
            const str_sh = shdrs[link * SHDR_SIZE ..][0..SHDR_SIZE];
            const strtab = slice(elf, r64(str_sh, 24), r64(str_sh, 32)) orelse return null;
            return .{ .symtab = symtab, .strtab = strtab };
        }
        return null;
    }

    /// Return the function symbol containing `addr`, or null if there is none.
    ///
    /// Prefers a function whose `[value, value + size)` range contains `addr`.
    /// Otherwise falls back to the nearest unsized symbol below `addr` (such
    /// as an assembly label) if it is at most 4 KiB away.
    pub fn lookup(self: Table, addr: u64) ?Symbol {
        var best_sized: ?Symbol = null;
        var best_unsized: ?Symbol = null;
        var unsized_value: u64 = 0;

        var off: usize = 0;
        while (off + SYM_SIZE <= self.symtab.len) : (off += SYM_SIZE) {
            const s = self.symtab[off..][0..SYM_SIZE];
            const typ = s[4] & 0xF;
            const shndx = r16(s, 6);
            const value = r64(s, 8);
            const size = r64(s, 16);
            if (typ != STT_FUNC and typ != STT_NOTYPE) continue;
            if (shndx == 0 or value > addr) continue; // undefined, or above addr
            const sym_name = self.stringAt(r32(s, 0)) orelse continue;
            if (sym_name.len == 0) continue;

            if (size != 0) {
                if (addr - value < size) best_sized = .{ .name = sym_name, .offset = addr - value };
            } else if (addr - value < UNSIZED_RANGE and (best_unsized == null or value > unsized_value)) {
                best_unsized = .{ .name = sym_name, .offset = addr - value };
                unsized_value = value;
            }
        }
        return best_sized orelse best_unsized;
    }

    /// Return the NUL-terminated string at offset `off` in the string table.
    fn stringAt(self: Table, off: u32) ?[]const u8 {
        if (off >= self.strtab.len) return null;
        const rest = self.strtab[off..];
        return rest[0 .. std.mem.indexOfScalar(u8, rest, 0) orelse return null];
    }
};

/// Return `len` bytes of `b` starting at `off`, or null if that range is not inside `b`.
fn slice(b: []const u8, off: u64, len: u64) ?[]const u8 {
    if (off > b.len or len > b.len - off) return null;
    return b[@intCast(off)..][0..@intCast(len)];
}

/// Read a little-endian u16 from `b` at byte offset `o`.
fn r16(b: []const u8, o: usize) u16 {
    return std.mem.readInt(u16, b[o..][0..2], .little);
}

/// Read a little-endian u32 from `b` at byte offset `o`.
fn r32(b: []const u8, o: usize) u32 {
    return std.mem.readInt(u32, b[o..][0..4], .little);
}

/// Read a little-endian u64 from `b` at byte offset `o`.
fn r64(b: []const u8, o: usize) u64 {
    return std.mem.readInt(u64, b[o..][0..8], .little);
}
