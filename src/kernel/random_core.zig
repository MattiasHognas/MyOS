//! The deterministic part of the kernel's random-number generator.
//!
//! `Generator` is ChaCha (the standard library's CSPRNG) with fast key
//! erasure: it expands a 32-byte seed into any amount of output and
//! overwrites its key as it goes, so a later look at the state does not
//! reveal earlier output. `mix` folds more input into the state at any
//! time. Input can be of any quality: mixing in a guessable value never
//! makes the output easier to guess, so the generator is at least as
//! unpredictable as the best thing it was ever given.
//!
//! Given the same input this gives the same output, which is what makes it
//! testable on the host; `random.zig` supplies the unpredictable input.

const std = @import("std");
const ChaCha = std.Random.ChaCha;

pub const SEED_LENGTH = ChaCha.secret_seed_length;

pub const Generator = struct {
    chacha: ChaCha,
    /// Bytes produced since the last `mix`.
    produced: u64 = 0,

    pub fn init(seed: [SEED_LENGTH]u8) Generator {
        return .{ .chacha = ChaCha.init(seed) };
    }

    /// Fill `buf` with random bytes.
    pub fn fill(self: *Generator, buf: []u8) void {
        self.chacha.fill(buf);
        self.produced += buf.len;
    }

    /// Fold `input` into the state. Output afterwards depends on the old
    /// state and on every byte of `input`.
    pub fn mix(self: *Generator, input: []const u8) void {
        self.chacha.addEntropy(input);
        self.produced = 0;
    }
};
