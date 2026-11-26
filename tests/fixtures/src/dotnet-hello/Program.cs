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
