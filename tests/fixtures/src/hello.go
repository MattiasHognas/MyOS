// A Go program for Linux, statically linked (the Go toolchain's default
// without cgo). Its runtime starts several threads before main, reserves
// a large part of the address space for its heap, and installs signal
// handlers; main then uses goroutines, a channel and the allocator.
package main

import (
	"fmt"
	"os"
	"runtime"
	"sync"
	"time"
)

var sink *int

func nilWrite() (msg string) {
	defer func() {
		if r := recover(); r != nil {
			msg = fmt.Sprint("recovered: ", r)
		}
	}()
	*sink = 1
	return "no fault"
}

func main() {
	fmt.Println("hello from go:", len(os.Args), "args")
	for i, a := range os.Args {
		fmt.Printf("argv[%d]=%s\n", i, a)
	}

	// Goroutines on every CPU the runtime sees, a channel, and enough
	// allocation for the garbage collector to have something to do.
	const workers = 8
	results := make(chan int, workers)
	var wg sync.WaitGroup
	for w := 0; w < workers; w++ {
		wg.Add(1)
		go func(w int) {
			defer wg.Done()
			sum := 0
			for i := 0; i < 20000; i++ {
				s := make([]int, 64)
				s[i%64] = i
				sum += s[i%64] % 7
			}
			results <- sum
		}(w)
	}
	wg.Wait()
	close(results)
	total := 0
	for r := range results {
		total += r
	}
	runtime.GC()
	fmt.Println("goroutines:", workers, "sum:", total, "cpus:", runtime.NumCPU())

	// A nil pointer: the runtime turns the fault (a signal) into a panic,
	// which recover catches.
	fmt.Println("nil pointer:", nilWrite())

	// With one processor, a goroutine that spins without a function call
	// gives the CPU back only when the runtime preempts it with a signal.
	old := runtime.GOMAXPROCS(1)
	stop := false
	go func() {
		for !stop {
		}
	}()
	time.Sleep(20 * time.Millisecond) // main runs again only if the spinner was preempted
	stop = true
	runtime.GOMAXPROCS(old)
	fmt.Println("preempted a spinning goroutine")
	if v := os.Getenv("GREETING"); v != "" {
		fmt.Println("GREETING=" + v)
	}
	os.Exit(len(os.Args))
}
