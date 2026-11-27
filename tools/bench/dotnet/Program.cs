// The .NET part of tools/bench: a multi-threaded workload, timed the same
// way on Linux and on MyOS. Built ahead of time and statically linked, so
// both kernels run the same program. Prints the CSV lines of bench.zig:
//
//     bench,<name>,<threads>,<median ns>,<min ns>,<max ns>
//
// for 1, 2, 4, ... threads up to the CPUs there are (at most 8), the time
// per operation of one thread:
//
//   dotnet_alloc       a small object allocated and soon dropped: the
//                      collector's allocation path and its collections
//   dotnet_cpu         arithmetic with no allocation: scaling alone
//   dotnet_threadpool  a work item queued to the thread pool and run:
//                      its queues, wake-ups and futexes
using System.Diagnostics;

const int Runs = 5;
const double RunSeconds = 0.15;
int cpus = Math.Min(Environment.ProcessorCount, 8);

for (int threads = 1; threads <= cpus; threads *= 2)
{
    Report("dotnet_alloc", threads, Measure(threads, Alloc));
    Report("dotnet_cpu", threads, Measure(threads, Cpu));
    Report("dotnet_threadpool", threads, MeasurePool(threads));
}
return 0;

// ns per operation of one thread, over `threads` threads each doing `op`
// for about RunSeconds; a warm-up first, then Runs runs.
static double[] Measure(int threads, Func<long, long> op)
{
    var samples = new double[Runs];
    for (int r = -1; r < Runs; r++)
    {
        var perThread = new double[threads];
        var workers = new Thread[threads];
        using var start = new Barrier(threads);
        for (int t = 0; t < threads; t++)
        {
            int me = t;
            workers[t] = new Thread(() =>
            {
                start.SignalAndWait();
                perThread[me] = TimeRun(op);
            });
            workers[t].Start();
        }
        foreach (var w in workers) w.Join();
        if (r >= 0) samples[r] = perThread.Average();
    }
    return samples;
}

// Grow the count until a run takes RunSeconds; ns per operation.
static double TimeRun(Func<long, long> op)
{
    long n = 1000;
    while (true)
    {
        long begin = Stopwatch.GetTimestamp();
        long sink = op(n);
        double seconds = Stopwatch.GetElapsedTime(begin).TotalSeconds;
        GC.KeepAlive(sink);
        if (seconds >= RunSeconds) return seconds * 1e9 / n;
        n = seconds <= 0 ? n * 16 : Math.Max(n * 2, (long)(n * RunSeconds / seconds) + 1);
    }
}

// The thread pool: `threads` producers each queue work items and wait for
// them in batches; ns per item.
static double[] MeasurePool(int threads)
{
    ThreadPool.SetMinThreads(threads, threads);
    return Measure(threads, n =>
    {
        long done = 0;
        const int Batch = 64;
        using var all = new CountdownEvent(1);
        for (long i = 0; i < n; i += Batch)
        {
            all.Reset(Batch);
            for (int j = 0; j < Batch; j++)
                ThreadPool.UnsafeQueueUserWorkItem(static e => ((CountdownEvent)e!).Signal(), all);
            all.Wait();
            done += Batch;
        }
        return done;
    });
}

static long Alloc(long n)
{
    // Keep the last few alive, as real code keeps some of what it makes.
    var keep = new object[64];
    long sum = 0;
    for (long i = 0; i < n; i++)
    {
        var a = new int[4];
        a[0] = (int)i;
        keep[i & 63] = a;
        sum += a.Length;
    }
    return sum + keep.Length;
}

static long Cpu(long n)
{
    ulong x = 0x9E3779B97F4A7C15;
    for (long i = 0; i < n; i++)
    {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
    }
    return (long)x;
}

static void Report(string name, int threads, double[] samples)
{
    Array.Sort(samples);
    var inv = System.Globalization.CultureInfo.InvariantCulture;
    Console.WriteLine(string.Format(inv, "bench,{0},{1},{2:F1},{3:F1},{4:F1}", name, threads, samples[Runs / 2], samples[0], samples[Runs - 1]));
}
