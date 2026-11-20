# Stuff to work on

1. Close the safety gaps

    **Fault-safe user memory access.**

    Right now a bad pointer passed to a syscall panics the kernel.
    Add copyFromUser/copyToUser that recover from page faults and turn on SMAP/SMEP so the kernel can’t touch user memory outside those functions by accident.

    **Double-fault stack (IST).**

    A kernel stack overflow currently ends in a triple fault and a silent reboot. With a separate stack for double faults we get a message instead.

    **Guard pages under kernel stacks**

    So that an overflow causes an immediate page fault instead of silently corrupting the heap.

2. Tests and CI

    Add coverage, unit as well as using real resources.

3. Make the shell useful

    Arguments to programs (cat /etc/motd), passed on the new process’s stack.
    readdir in the VFS, and with it ls.
    A few small programs: cat, ls, echo.

4. FAT32 on the NVMe disk

    Persistent storage. Fill image from Linux with mkfs.fat and mcopy, so it’s easy to test.

5. SMP (using all CPU cores)

    Every place that currently uses “disable interrupts” as a lock becomes a real spinlock and per-CPU state moves behind swapgs.

6. Networking

    e1000e driver, then a small TCP/IP stack.

7. Port a libc

    Execute c programs.

8. Graphical desktop

    ...
