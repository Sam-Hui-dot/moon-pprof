package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime/pprof"
)

//go:noinline
func fastHashLoop(iters int) uint64 {
	var h uint64 = 1469598103934665603
	for i := 0; i < iters; i++ {
		h ^= uint64(i)
		h *= 1099511628211
		h ^= h >> 33
	}
	return h
}

//go:noinline
func slowRegressionLoop(iters int) uint64 {
	var acc uint64 = 1
	for i := 1; i <= iters; i++ {
		x := uint64(i)
		for j := 0; j < 8; j++ {
			x = (x*6364136223846793005 + 1442695040888963407) ^ (x >> 17)
		}
		acc ^= x
	}
	return acc
}

//go:noinline
func runWorkload(regressed bool) uint64 {
	sink := fastHashLoop(120_000_000)
	if regressed {
		sink ^= slowRegressionLoop(110_000_000)
	} else {
		sink ^= slowRegressionLoop(15_000_000)
	}
	return sink
}

func capture(path string, regressed bool) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := pprof.StartCPUProfile(f); err != nil {
		return err
	}
	sink := runWorkload(regressed)
	pprof.StopCPUProfile()
	fmt.Printf("captured %s (sink=%d)\n", path, sink)
	return nil
}

func main() {
	outDir := "demo/fixtures"
	if len(os.Args) > 1 {
		outDir = os.Args[1]
	}
	if err := capture(filepath.Join(outDir, "baseline-cpu.pb.gz"), false); err != nil {
		panic(err)
	}
	if err := capture(filepath.Join(outDir, "candidate-cpu.pb.gz"), true); err != nil {
		panic(err)
	}
}
