// A Rust program for Linux, linked statically against musl. It uses the
// standard library as any program does: arguments, the environment, a
// growable vector and a formatted line on standard output.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    println!("hello from rust: {} args", args.len());
    for (i, a) in args.iter().enumerate() {
        println!("argv[{}]={}", i, a);
    }
    // Enough allocation to make the allocator ask the kernel for memory.
    let squares: Vec<u64> = (0..100_000u64).map(|n| n * n).collect();
    let sum: u64 = squares.iter().sum();
    println!("sum of squares below 100000: {}", sum);
    if let Ok(v) = std::env::var("GREETING") {
        println!("GREETING={}", v);
    }
    std::process::exit(args.len() as i32);
}
