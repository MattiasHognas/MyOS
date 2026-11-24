# Concurrency and locking

How kernel code stays correct when it can be interrupted, preempted and, from
milestone 3 on, run on several CPUs at once. This is the model the SMP work
follows ([roadmap 3.1](todo.md#31-synchronization)).

**Status: proposed.** The rules below are decided on paper. "Today" says what
the code does now, on one CPU; "With several CPUs" says what changes. Nothing
here is implemented until its roadmap item is ticked. The blocking protocols
have been model-checked (see [the end](#what-has-been-checked)); the rest
follows from reading the code.

## The model in one page

- **Kernel code is preemptible.** A timer interrupt can switch threads in the
  middle of any kernel code that has interrupts on, including a syscall.
- **A spinlock turns interrupts off while it is held**, so its holder is
  never preempted and never interrupted. There is one kind of spinlock; every
  one may be taken from an interrupt handler.
- **Nothing blocks while it holds a spinlock.** Code that has to wait while
  it holds something uses a `Mutex`.
- **Interrupt handlers do not block.** They may take spinlocks and wake
  threads.
- **Each piece of shared state has one lock**, named below. State that
  belongs to a CPU needs no lock, only interrupts off.
- **Locks are taken in one order**, given below. A lock is never taken while
  one further down the list is held.
- **Waiting is always "check and sleep under the lock the waker takes".**
  There is no other way to wait.

## What changes with several CPUs

Today one rule carries most of the kernel: with interrupts off, nothing else
runs. So "turn interrupts off, look, act" is atomic, and the scheduler, the
process tree, the keyboard buffer and the console rely on exactly that.

With several CPUs, turning interrupts off stops only this CPU. Every one of
those sections needs a lock that the other CPUs take too. The places are
listed in [roadmap 3.1](todo.md#31-synchronization); this document says which
lock each gets.

## Locks and what they protect

| Lock | Protects | Today |
| --- | --- | --- |
| Scheduler lock (one, global, to begin with) | The ready queue, every thread's `state`, `link` and wake-up permit, the zombie list | Interrupts off |
| Process-tree lock (one, global) | Parent and child links, descendant counts, reference counts, exit status | Interrupts off |
| A condition's lock | A condition some thread waits for, together with the wait queue for it: the keyboard buffer and its readers, a mutex's owner and its waiters | Interrupts off; the wait queue has a lock of its own |
| Timer lock | The timer queue and the tick count | A spinlock already |
| Heap lock | The kernel heap, and the page tables of the heap's region | A spinlock already |
| Kernel-stack lock | The stack slots, and the page tables of the stack region | A spinlock already |
| Page-allocator lock | The page bitmaps | A spinlock already |
| Random-generator lock | The generator's state | A spinlock already |
| Console lock | The serial port and the framebuffer console | Interrupts off |
| A process's address-space lock | Its user page tables and, from milestone 5, its regions | Not needed: one thread per process |
| A process's descriptor-table lock | Its open files | Not needed: one thread per process |

Two points about this table.

**Kernel page tables need no lock of their own.** The heap, the kernel stacks,
the device window and the direct map each occupy their own top-level slot of
the address space, and the tables under all those slots are allocated at
boot. So the heap and the stack allocator never touch the same page table,
and each region's own lock is enough. A new kernel region must take a slot
of its own to keep this true.

**A wait queue is protected by its condition's lock, not by a lock of its
own.** The waiter has to hold the condition's lock anyway while it checks the
condition and joins the queue; a second lock would only add an ordering rule.

## Lock order

Outermost first. Holding a lock, code may take any lock below it and none
above it.

1. Process-tree lock
2. A process's address-space lock, then its descriptor-table lock
3. A condition's lock (including a mutex's internal lock)
4. Timer lock
5. Scheduler lock
6. Heap lock or kernel-stack lock (never both)
7. Page-allocator lock
8. Random-generator lock
9. Console lock

What follows from the order:

- **The scheduler lock is nearly innermost.** Code that holds it does not
  allocate, free or print, except to panic. So a thread structure and its
  stack are allocated before the lock is taken, and exited threads are freed
  after it is released.
- **Waking takes the scheduler lock**, so a thread may be woken while a
  condition's lock or the timer lock is held, and not while an allocator's
  lock is held.
- **Timer callbacks run with the timer lock released**, as today, so a
  callback may arm or cancel timers and wake threads.
- **The console lock is innermost**, so anything may print. A panic does not
  wait for it: the CPU that panics stops the others and takes the console.

## Sleeping and waking

The pattern, for every kind of waiting:

```
waiter:  take the condition's lock
         while the condition does not hold:
             join the wait queue; release the lock; block; take the lock again
         release the lock

waker:   take the condition's lock
         make the condition hold; take a thread off the wait queue
         wake that thread
         release the lock
```

**The waker wakes the thread before it releases the condition's lock.** A
waiter with a timeout can leave the wait queue on its own, return and exit.
It needs the condition's lock to leave, so while the waker holds that lock
the thread it took off the queue is still there to be woken. Released
first, the waker could wake a thread that is gone.

`WaitQueue.wait` takes the held lock as its argument and does the middle
line; callers never join a queue and block in two steps of their own.

A wake-up can arrive between the waiter's "release the lock" and "block".
The permit covers that, as today: `wake` on a thread that is not blocked
leaves a permit, and `block` returns at once when it finds one. With several
CPUs the permit, the thread's state and the ready queue all change under the
scheduler lock.

**A thread is not runnable until its CPU has left its stack.** When a thread
blocks, it marks itself blocked and then switches stacks. If the scheduler
lock were released between the two, another CPU could wake the thread, a
third could pick it from the ready queue, and two CPUs would run on one
stack. So the scheduler lock is held across the context switch and released
by the thread that is switched to. A new thread's first code releases it too.

**A timer callback and the thread that armed the timer can run at once.**
Today a callback runs to completion inside the timer interrupt before the
waiting thread can run, so `sleepTicks` and `waitTimeout` keep their timer in
the waiter's stack frame and return as soon as they wake. With several CPUs
the callback may still be running on another CPU when the waiter returns,
and would then write to a dead stack frame or wake a thread that has
exited. Two rules prevent it:

- `timer.cancel` says whether it removed the timer. If it did not, the
  callback has started, and the caller waits until the callback says it has
  finished before it lets the timer go.
- A callback sets "fired" before it wakes the thread, so the thread's loop
  sees it, and sets "finished" as the last thing it does, after which it
  touches nothing of the waiter's. One flag cannot do both jobs: set before
  the wake, the waiter may leave too early; set after, the waiter may see it
  unset, block again and never be woken.

## Per-CPU state

Reached through GS (`percpu.zig`); touched only with interrupts off, by the
CPU it belongs to, without a lock.

- The running thread and what is left of its time slice.
- The loaded address space (`vmm.loadedRoot`) and the count of CR3 loads.
- The kernel stack pointers for `syscall` entry and for interrupts from ring
  3 (the TSS), so each CPU has its own GDT, TSS and emergency stacks.
- The thread whose extended (x87/SSE/AVX) state is in the registers.
- The count of halts.

Each CPU starts in a boot context of its own, which becomes a thread and
retires (`thread.retire`) once the CPU is up. There is still no idle thread:
a CPU with nothing to run halts inside `block` of whichever thread it ran
last.

## Address spaces and the TLB

- **User mappings.** Removing a mapping or making it stricter must reach
  every CPU that has that address space loaded. That includes a CPU running
  a kernel thread: a kernel thread keeps whichever address space was loaded
  (`thread.zig`). So each address space records the CPUs it is loaded on,
  and the record changes where CR3 is loaded.
- **Kernel mappings** are global and the same everywhere, so removing one (a
  freed kernel stack) must reach every CPU.
- **Order.** Clear the page-table entries, flush on every CPU concerned, and
  only then free the page tables and the pages. `vmm.unmap` frees tables and
  returns the page before it flushes today, which is correct on one CPU only
  ([roadmap 3.4](todo.md#34-smp-scheduling-and-memory)).
- **Tearing down an address space.** It must be loaded on no CPU.
  `vmm.unloadRoot` does that for this CPU today; with several, teardown asks
  the others to switch away first.

## What interrupt handlers may do

- Take spinlocks, wake threads, arm and cancel timers.
- Not block, not take a mutex, not allocate from the heap in a path that can
  be avoided (the heap lock is a spinlock, so it is safe, but it is slow).
- A handler may switch threads on its way out, as the timer does. It must
  hold no lock when it does.

## Checks in the code

To be added with the items that implement the model:

- A count of spinlocks held on each CPU. `block` and the context switch
  assert it is what they expect (zero, or just the scheduler lock).
- Each lock has a rank from the list above; taking one whose rank is not
  below the innermost lock held is an assertion failure in the test kernel.
- The existing "held absurdly long" panic of `SpinLock` stays: with several
  CPUs it is how a deadlock shows itself.

## Decisions left to later items

- **One ready queue or one per CPU** ([3.4](todo.md#34-smp-scheduling-and-memory)).
  The global scheduler lock above is the starting point because it makes the
  switch-out rule simple. Per-CPU queues replace the lock with one per queue
  plus a per-thread "still on a CPU" flag.
- **One process-tree lock or finer ones.** One lock is enough until `fork`
  or `wait4` make the tree hot.

## What has been checked

The blocking protocols above are checked as models: small descriptions of
each protocol's steps, tried in every order the steps can happen
(`tools/modelcheck`, models in `tests/models/`, run by `zig build
check-models`; see [testing](testing.md#model-checks)). For each rule there
is also a model with the rule switched off, which must fail:

| Rule | With it | Without it |
| --- | --- | --- |
| Check the condition and join the queue under the lock the waker takes | No wake-up is lost | A waiter sleeps for good |
| Hold the scheduler lock across the context switch | No thread runs on two CPUs | One does |
| "Fired" before the wake and "finished" last | The waiter returns and is not touched afterwards | Unsynchronized, or one flag before the wake: a thread that has gone is woken. One flag after the wake: the waiter sleeps for good |
| Wake before releasing the condition's lock | The woken thread is still there | With timeouts, a thread that has gone is woken. Without timeouts it happens to be safe |
| Look at a mutex's owner and take it under one lock | One owner at a time; every waiter gets in | Two threads are inside at once |

A model is not the code: these results say the design holds, and each model
names the functions it describes so that the two can be kept in step. The
lock order, the per-CPU rules and the TLB rules are not modelled; they
follow from reading the code.
