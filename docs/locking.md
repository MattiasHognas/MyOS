# Concurrency and locking

How kernel code stays correct when it can be interrupted, preempted and, from
milestone 3 on, run on several CPUs at once. This is the model the SMP work
follows ([roadmap 3.1](todo.md#31-synchronization)).

**Status: the locks are in the code; there is still one CPU.** Everything
under "Locks and what they protect", "Lock order", "Sleeping and waking" and
"Checks in the code" is implemented and tested, as far as one CPU can test
it: every critical section that relied on "interrupts off means nothing else
runs" now takes a lock that other CPUs would take too. What waits for the
CPUs themselves is marked "not yet" below: state that belongs to a CPU is
still one global copy (3.2), and nothing is sent from one CPU to another
(3.4), which the TLB rules and waking an idle CPU need. The blocking
protocols have been model-checked (see [the end](#what-has-been-checked)).

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

## What changed for several CPUs

On one CPU a single rule carried most of the kernel: with interrupts off,
nothing else runs. So "turn interrupts off, look, act" was atomic, and the
scheduler, the process tree, the keyboard buffer and the console relied on
exactly that.

With several CPUs, turning interrupts off stops only this CPU. Every one of
those sections now takes a lock that the other CPUs take too. Turning
interrupts off on its own is left for one purpose: touching state that
belongs to this CPU.

## Locks and what they protect

| Lock | Rank | Protects | Where |
| --- | --- | --- | --- |
| Process-tree lock (one, global) | `process_tree` | Parent and child links, descendant counts, reference counts, exit statuses and the threads waiting for them | `process.zig` |
| A process's address-space lock | `address_space` | Its user page tables and, from milestone 5, its regions | Not yet needed: one thread per process |
| A process's descriptor-table lock | `descriptor_table` | Its open files | Not yet needed: one thread per process |
| A condition's lock | `condition` | A condition some thread waits for, together with the wait queue for it: the keyboard buffer and its readers, a mutex's owner and its waiters | `ps2_keyboard.zig`, `sync/mutex.zig` |
| Timer lock | `timer` | The timer queue and the tick count | `timer.zig` |
| Scheduler lock (one, global, to begin with) | `scheduler` | The ready queue, every thread's `state`, `link`, `on_cpu` and wake-up permit, the zombie list | `thread.zig` |
| Heap lock | `kernel_region` | The kernel heap, and the page tables of the heap's region | `heap.zig` |
| Kernel-stack lock | `kernel_region` | The stack slots, and the page tables of the stack region | `kstack.zig` |
| Device-window lock | `kernel_region` | Where the next device mapping goes, and the page tables of the device window | `vmm.zig` |
| Page-allocator lock | `page_allocator` | The page bitmaps | `pmm.zig` |
| Random-generator lock | `random` | The generator's state | `random.zig` |
| Console lock | `console` | The serial port and the framebuffer console | `main.zig` |

The rank is the lock's place in the lock order (`sync/lock_order.zig`); every
`SpinLock` carries one.

Two points about this table.

**Kernel page tables need no lock of their own.** The heap, the kernel stacks,
the device window and the direct map each occupy their own top-level slot of
the address space, and the tables those slots point at are allocated at
boot. So the top-level table never changes, two regions never touch the same
page table below it, and each region's own lock is enough. A new kernel
region must take a slot and a lock of its own to keep this true.

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
6. Heap lock, kernel-stack lock or device-window lock (never two of them)
7. Page-allocator lock
8. Random-generator lock
9. Console lock

Two locks of the same rank are never held together either: not two
conditions' locks, not two regions' locks.

What follows from the order:

- **The scheduler lock is nearly innermost.** Code that holds it does not
  allocate, free or print, except to panic. So a thread structure and its
  stack are allocated before the lock is taken, and exited threads are freed
  after it is released.
- **Waking takes the scheduler lock**, so a thread may be woken while a
  condition's lock or the timer lock is held, and not while an allocator's
  lock is held.
- **Timer callbacks run with the timer lock released**, so a
  callback may arm or cancel timers and wake threads.
- **The process-tree lock is outermost**, and held for a few lines at a
  time: a new process's memory and its thread are allocated before it is
  taken (`thread.create`), and a process structure is freed after it is
  released.
- **The console lock is innermost**, so anything may print. A CPU that
  reports a panic or a kernel fault does not wait for it
  (`root.seizeConsole`): it may be the one holding it. Not yet: stopping
  the other CPUs first, so that nothing else is printed in between (3.4).

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
The permit covers that: `wake` on a thread that is not blocked leaves a
permit, and `block` returns at once when it finds one. The permit, the
thread's state and the ready queue all change under the scheduler lock.

**A thread is not runnable until its CPU has left its stack.** When a thread
blocks, it marks itself blocked and then switches stacks. If the scheduler
lock were released between the two, another CPU could wake the thread, a
third could pick it from the ready queue, and two CPUs would run on one
stack. So the scheduler lock is held across the context switch and released
by the thread that is switched to (`finishSwitch` in `thread.zig`). A new
thread's first code releases it too. For the same reason a thread that has
exited goes on the list of threads to free only there, once its CPU has left
its stack.

**A blocked thread can still have a CPU on its stack.** There is no idle
thread: a CPU whose thread blocks and finds nothing else to run halts right
there, with the scheduler lock released. Every thread records whether a CPU
is on its stack (`on_cpu`, changed under the scheduler lock). Waking a
blocked thread that has one just marks it running, and it carries on where
it is; putting it in the ready queue would let a second CPU run on the same
stack. Because the lock covers every switch, "blocked, with a CPU on its
stack, and the lock free" can only mean "idling". Not yet: the waking CPU
has to interrupt the halted one, which until then notices at its next timer
tick (3.4).

**A timer callback and the thread that armed the timer can run at once.**
On one CPU a callback runs to completion inside the timer interrupt before
the waiting thread can run. With several CPUs the callback may still be
running on another CPU when the waiter returns, and `sleepTicks` and
`waitTimeout` keep their timer in the waiter's stack frame: the callback
would write to a dead frame or wake a thread that has exited. Two rules
prevent it, and `timer.WakeTimer` is the one place that implements them:

- `timer.cancel` says whether it removed the timer. If it did not, the
  callback has started, and the caller waits until the callback says it has
  finished before it lets the timer go (`WakeTimer.finish`).
- A callback sets "fired" before it wakes the thread, so the thread's loop
  sees it, and sets "finished" as the last thing it does, after which it
  touches nothing of the waiter's. One flag cannot do both jobs: set before
  the wake, the waiter may leave too early; set after, the waiter may see it
  unset, block again and never be woken.

The wait for "finished" is a short spin, with the condition's lock held if
there is one: the callback takes only the scheduler lock, so it cannot be
waiting for the spinning thread.

## Per-CPU state

Reached through GS (`percpu.zig`); touched only with interrupts off, by the
CPU it belongs to, without a lock.

There today:

- The kernel stack pointer for `syscall` entry.
- The spinlocks the CPU holds (see [checks](#checks-in-the-code)).

Still one global copy, to move there in 3.2:

- The running thread and what is left of its time slice.
- The loaded address space (`vmm.loadedRoot`) and the count of CR3 loads.
- The kernel stack pointer for interrupts from ring 3 (the TSS), so each CPU
  gets its own GDT, TSS and emergency stacks.
- The thread whose extended (x87/SSE/AVX) state is in the registers.
- The count of halts.

Each CPU starts in a boot context of its own, which becomes a thread and
retires (`thread.retire`) once the CPU is up. There is still no idle thread:
a CPU with nothing to run halts inside `block` of whichever thread it ran
last.

## Address spaces and the TLB

Not yet in the code: these are the rules for 3.4. Today `unmap` and the
teardown of an address space are correct for one CPU only.

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

In builds with assertions (the default, and every test kernel), on one CPU
as on several:

- **Each CPU records the spinlocks it holds**, by rank, in its per-CPU
  structure (`lock_order.Stack`). Taking a lock whose rank is not after
  every lock held panics before the CPU spins on it, naming both; so does
  releasing a lock that is not the innermost. A wrong order is therefore
  found the first time the code runs, not the day two CPUs meet in it.
- **`block`, `yield`, `exit` and the context switch assert the count**:
  none held, or just the scheduler lock at the switch. So is sleeping with
  a spinlock held, and taking a mutex with one.
- **`WaitQueue.wait` asserts that the condition's lock is held** and is
  the only one; `wakeOne`, `wakeAll` and `waiting` that some lock is.
- The "held absurdly long" panic of `SpinLock` stays: with several CPUs it
  is how a deadlock that slipped past the ranks shows itself.

A CPU that is reporting a panic or a kernel fault stops checking: it prints
whatever it holds.

## System calls and contention

The scalable commutativity rule ([research](research.md)) says: whenever two
calls commute (the result is the same whichever runs first, and nothing
later can tell), they can be implemented so that they share no written
memory, and then they scale. So for every pair of calls there is a question
with a definite answer: must they contend? The calls that exist today:

| Calls | Commute? | Contend today on | Verdict |
| --- | --- | --- | --- |
| `gettid`, with anything | Yes | Nothing | As it should be |
| `read` on different open files | Yes | Nothing (the initrd is read-only; the offset is the file's own) | As it should be |
| `read` twice on one open file | No: each moves the offset | The offset | Cannot be avoided; needs the file's lock once two threads can share one (7) |
| `write` to the console, twice | No: the order shows on the screen | Console lock | Cannot be avoided |
| `myos_getchar`, twice | No: who gets which key | Keyboard lock | Cannot be avoided |
| `open` twice in one process | No: `open` returns the lowest free descriptor, so each sees the other | The descriptor table | Cannot be avoided (POSIX); needs the descriptor-table lock with threads (7) |
| `open` or `close` in different processes | Yes | Heap lock (the open-file structure) | To fix: per-CPU heap caches (3.4) |
| `close` of different descriptors in one process | Yes | Heap lock; the table with threads | To fix with the heap; a lock per table is enough for the rest |
| `sched_yield` on different CPUs | Yes | Scheduler lock | To fix: per-CPU ready queues (3.4 decides) |
| `exit` of unrelated processes | Yes | Process-tree lock, scheduler lock, page-allocator and heap locks when the thread is freed | Allocators: 3.4. The tree lock stays one until `fork` or `wait4` make it hot |
| `exit` of a child and of its parent | No: who inherits the grandchildren | Process-tree lock | Cannot be avoided |
| `myos_run` in different processes | Yes | All of the above, and the kernel-stack lock | As `exit`; `myos_run` goes away with `fork` and `execve` (6) |

Not system calls, but on every CPU all the time: the timer tick takes the
timer lock, and a thread switch the scheduler lock. Both are global to begin
with and are the first to split when measurements say so.

## Decisions left to later items

- **One ready queue or one per CPU** ([3.4](todo.md#34-smp-scheduling-and-memory)).
  The global scheduler lock above is the starting point because it makes the
  switch-out rule simple. Per-CPU queues replace the lock with one per
  queue; the per-thread `on_cpu` flag they need is already there.
- **Who advances time.** One CPU counts ticks and runs the timer queue, or
  every CPU has a queue of its own ([3.3](todo.md#33-bring-up-application-processors)).
  The callbacks are safe either way.
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
| Hold the scheduler lock across the context switch | No thread runs on two CPUs | One does; or, woken "in place" while it is leaving its stack, one is never run again |
| Wake a blocked thread whose CPU idles on its stack in place | It carries on there | Put in the ready queue, it runs on two CPUs |
| "Fired" before the wake and "finished" last | The waiter returns and is not touched afterwards | Unsynchronized, or one flag before the wake: a thread that has gone is woken. One flag after the wake: the waiter sleeps for good |
| Wake before releasing the condition's lock | The woken thread is still there | With timeouts, a thread that has gone is woken. Without timeouts it happens to be safe |
| Look at a mutex's owner and take it under one lock | One owner at a time; every waiter gets in | Two threads are inside at once |

A model is not the code: these results say the design holds, and each model
names the functions it describes so that the two can be kept in step. The
lock order is not modelled but enforced as the kernel runs (see
[checks](#checks-in-the-code)). The per-CPU rules and the TLB rules are
neither; they follow from reading the code.

What one CPU cannot show is two CPUs inside these protocols at the same
moment. The tests that need that are listed in
[roadmap 3.4](todo.md#34-smp-scheduling-and-memory) and run once the other
CPUs are started.
