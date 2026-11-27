// A .NET program for the kernel tests: arguments, the environment, threads
// that allocate, a garbage collection. Exits with its number of arguments.
using System;
using System.Threading;

Console.WriteLine($"hello from dotnet: {args.Length} args");

long sum = 0;
var threads = new Thread[8];
for (int i = 0; i < threads.Length; i++)
{
    threads[i] = new Thread(() =>
    {
        long local = 0;
        for (int j = 0; j < 1000; j++)
        {
            var block = new byte[1024];
            local += block.Length + j;
        }
        Interlocked.Add(ref sum, local);
    });
    threads[i].Start();
}
foreach (var t in threads) t.Join();
GC.Collect();

Console.WriteLine($"threads: {threads.Length} sum: {sum} cpus: {Environment.ProcessorCount} collected: {GC.CollectionCount(0) > 0}");

// A thread that spins without calls or allocation: the collector cannot
// wait for it to reach a safe point, and stops it with a signal instead.
// If it could not, the collections below would wait for ever.
int stop = 0;
long spins = 0;
var spinner = new Thread(() =>
{
    long n = 0;
    while (Volatile.Read(ref stop) == 0) n++;
    spins = n;
});
spinner.Start();
while (Volatile.Read(ref spins) == 0 && spinner.ThreadState == ThreadState.Unstarted) Thread.Yield();
Thread.Sleep(20); // spinning by now
int before = GC.CollectionCount(2);
for (int i = 0; i < 3; i++) GC.Collect(2, GCCollectionMode.Forced, blocking: true);
Volatile.Write(ref stop, 1);
spinner.Join();
Console.WriteLine($"collected around a spinning thread: {GC.CollectionCount(2) - before >= 3}");

// The collector sizes itself by the control group's memory limit where
// there is one (in a container on Linux; on MyOS, the process's own).
const string limitFile = "/sys/fs/cgroup/memory.max";
bool honored = true;
if (System.IO.File.Exists(limitFile) && long.TryParse(System.IO.File.ReadAllText(limitFile).Trim(), out long limit))
    honored = GC.GetGCMemoryInfo().TotalAvailableMemoryBytes <= limit;
Console.WriteLine($"memory limit honored: {honored}");
Console.WriteLine($"GREETING={Environment.GetEnvironmentVariable("GREETING")}");

// Faults that the runtime turns into exceptions (through signals: a null
// dereference is a SIGSEGV, a division by zero a SIGFPE).
try
{
    string? nothing = args.Length > 100 ? "x" : null;
    Console.WriteLine(nothing!.Length);
}
catch (NullReferenceException)
{
    Console.WriteLine("caught: NullReferenceException");
}
try
{
    int zero = args.Length > 100 ? 1 : 0;
    Console.WriteLine(1 / zero);
}
catch (DivideByZeroException)
{
    Console.WriteLine("caught: DivideByZeroException");
}
return args.Length;
