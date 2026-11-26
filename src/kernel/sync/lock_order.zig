//! The order spinlocks are taken in, and the record of which ones a CPU holds.
//!
//! Every spinlock has a rank (`docs/locking.md`, "Lock order"). A CPU may
//! take a lock only if its rank is higher than that of every lock it
//! already holds, so two CPUs can never wait for each other's locks. Each
//! CPU keeps the ranks of the locks it holds in a `Stack`; `spinlock.zig`
//! updates it and panics when the order is broken.
//!
//! Only the bookkeeping: no kernel dependencies, tested on the host.

/// What a lock protects, outermost first. Holding a lock, code may take
/// any lock further down the list and none further up or on the same line.
pub const Rank = enum(u8) {
    /// Parent and child links, descendant counts, reference counts and exit
    /// statuses of processes.
    process_tree = 1,
    /// One process's user page tables.
    address_space,
    /// One process's open files.
    descriptor_table,
    /// A condition some thread waits for, with the wait queue for it: the
    /// keyboard buffer, a mutex's owner. The default.
    condition,
    /// The timer queue and the tick count.
    timer,
    /// The ready queue and every thread's scheduling state.
    scheduler,
    /// A region of kernel address space and its page tables: the heap, the
    /// kernel stacks, the device window. Never two of them at once.
    kernel_region,
    /// One CPU's cache of free pages (`pmm.zig`). Never two at once.
    page_cache,
    /// The page bitmaps.
    page_allocator,
    /// The random generator's state.
    random,
    /// The serial port and the framebuffer console. Innermost, so anything
    /// may print.
    console,
};

/// The locks one CPU holds, in the order it took them.
pub const Stack = extern struct {
    /// Ranks of the locks held, innermost last.
    ranks: [capacity]u8 = @splat(0),
    len: u32 = 0,

    /// More than the deepest nesting the lock order allows for.
    pub const capacity = 12;

    pub const PushError = error{
        /// The lock's rank is not higher than that of the innermost lock held.
        OutOfOrder,
        /// More locks than `capacity`.
        TooDeep,
    };

    /// Record that a lock of `rank` is about to be taken. On error nothing
    /// is recorded.
    pub fn push(self: *Stack, rank: Rank) PushError!void {
        if (self.innermost()) |inner| {
            if (@backingInt(rank) <= @backingInt(inner)) return error.OutOfOrder;
        }
        if (self.len == capacity) return error.TooDeep;
        self.ranks[self.len] = @backingInt(rank);
        self.len += 1;
    }

    /// Record that the innermost lock, which must be of `rank`, was
    /// released. Fails, changing nothing, if the innermost lock is another
    /// one: locks are released in the opposite order they were taken in.
    pub fn pop(self: *Stack, rank: Rank) error{NotInnermost}!void {
        const inner = self.innermost() orelse return error.NotInnermost;
        if (inner != rank) return error.NotInnermost;
        self.len -= 1;
    }

    /// The rank of the lock taken last, or null if none is held.
    pub fn innermost(self: *const Stack) ?Rank {
        if (self.len == 0) return null;
        return @fromBackingInt(@intCast(self.ranks[self.len - 1]));
    }

    /// Number of locks held.
    pub fn count(self: *const Stack) usize {
        return self.len;
    }

    /// True if a lock of `rank` is held.
    pub fn holds(self: *const Stack, rank: Rank) bool {
        for (self.ranks[0..self.len]) |r| {
            if (r == @backingInt(rank)) return true;
        }
        return false;
    }
};
