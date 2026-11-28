// A .NET program that is an app rather than a hello-world, for MyOS's
// tests: the generic host with a configuration file that reloads when it
// changes (a FileSystemWatcher under it, on inotify), a FileSystemWatcher
// of its own, Process.Start of a child with its output read, File.Copy, a
// named Mutex held across processes, and the console in raw mode. Each
// step prints what it found; the exit code is the number that failed.
using System.Diagnostics;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

if (args.Length > 0 && args[0] == "child")
{
    // Started by the parent: say so, try the parent's mutex, end with 7.
    Console.WriteLine($"child: {args.Length - 1} args, pid {Environment.ProcessId}");
    using var mutex = new Mutex(false, "myos-realapp-mutex");
    Console.WriteLine($"child: mutex taken: {mutex.WaitOne(0)}"); // the parent holds it
    return 7;
}

int failed = 0;
void Check(string what, bool ok)
{
    Console.WriteLine($"realapp: {what}: {(ok ? "ok" : "FAIL")}");
    if (!ok) failed++;
}

var root = Path.Combine(Path.GetTempPath(), $"realapp-{Environment.ProcessId}");
Directory.CreateDirectory(root);
var settings = Path.Combine(root, "appsettings.json");
File.WriteAllText(settings, """{ "Greeting": "first" }""");

// --- The generic host, its configuration reloaded when the file changes.
var builder = Host.CreateApplicationBuilder(new HostApplicationBuilderSettings
{
    ContentRootPath = root,
    Args = Array.Empty<string>(),
});
builder.Logging.ClearProviders();
builder.Configuration.Sources.Clear();
builder.Configuration.AddJsonFile(settings, optional: false, reloadOnChange: true);
using var host = builder.Build();
await host.StartAsync();
var config = host.Services.GetRequiredService<IConfiguration>();
Check($"config read ({config["Greeting"]})", config["Greeting"] == "first");
var reloaded = new TaskCompletionSource();
using (config.GetReloadToken().RegisterChangeCallback(_ => reloaded.TrySetResult(), null))
{
    File.WriteAllText(settings, """{ "Greeting": "second" }""");
    var done = await Task.WhenAny(reloaded.Task, Task.Delay(10_000)) == reloaded.Task;
    // The reload may come a moment after the token fires.
    for (int i = 0; i < 50 && config["Greeting"] != "second"; i++) await Task.Delay(100);
    Check($"config reloaded ({config["Greeting"]})", done && config["Greeting"] == "second");
}

// --- A FileSystemWatcher of its own.
using (var watcher = new FileSystemWatcher(root) { EnableRaisingEvents = true })
{
    var created = new TaskCompletionSource<string>();
    watcher.Created += (_, e) => created.TrySetResult(e.Name ?? "");
    File.WriteAllText(Path.Combine(root, "made.txt"), "x");
    var seen = await Task.WhenAny(created.Task, Task.Delay(10_000)) == created.Task;
    Check($"FileSystemWatcher saw a file made ({(seen ? created.Task.Result : "nothing")})", seen && created.Task.Result == "made.txt");
}

// --- File.Copy.
var copy = Path.Combine(root, "copy.json");
File.Copy(settings, copy);
Check("File.Copy", File.ReadAllText(copy) == File.ReadAllText(settings));

// --- A named mutex, held while a child tries for it.
using (var mutex = new Mutex(false, "myos-realapp-mutex"))
{
    Check("named mutex taken", mutex.WaitOne(0));
    // --- Process.Start of a child, its output read.
    var start = new ProcessStartInfo(Environment.ProcessPath!, ["child", "a", "b"])
    {
        RedirectStandardOutput = true,
        UseShellExecute = false,
    };
    // Synchronous while the mutex is held: it is the thread's, and an
    // await could go on on another thread.
    using var child = Process.Start(start)!;
    var output = child.StandardOutput.ReadToEnd();
    child.WaitForExit();
    Check($"child ran (exit {child.ExitCode})", child.ExitCode == 7 && output.Contains("child: 2 args"));
    Check("child could not take the mutex", output.Contains("child: mutex taken: False"));
    mutex.ReleaseMutex();
}

// --- The console in raw mode, and back.
if (!Console.IsInputRedirected)
{
    Console.TreatControlCAsInput = true;
    var raw = Console.TreatControlCAsInput;
    Console.TreatControlCAsInput = false;
    Check("console raw mode", raw && !Console.TreatControlCAsInput);
}

await host.StopAsync();
Directory.Delete(root, recursive: true);
Console.WriteLine(failed == 0 ? "realapp: all correct" : $"realapp: {failed} failed");
return failed;
