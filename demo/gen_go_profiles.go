package main

import (
	"fmt"
	"os"
	"path/filepath"
	"runtime"
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

//go:noinline
func allocBaselineChunk(count int) [][]byte {
	out := make([][]byte, 0, count)
	for i := 0; i < count; i++ {
		buf := make([]byte, 4096)
		buf[0] = byte(i)
		out = append(out, buf)
	}
	return out
}

//go:noinline
func allocRegressedChunk(count int) [][]byte {
	out := make([][]byte, 0, count)
	for i := 0; i < count; i++ {
		buf := make([]byte, 16384)
		buf[0] = byte(i)
		out = append(out, buf)
	}
	return out
}

func captureCPU(path string, regressed bool) error {
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

func captureHeap(path string, regressed bool) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	oldRate := runtime.MemProfileRate
	runtime.MemProfileRate = 1
	defer func() { runtime.MemProfileRate = oldRate }()

	keepA := allocBaselineChunk(64)
	var keepB [][]byte
	if regressed {
		keepB = allocRegressedChunk(128)
	} else {
		keepB = allocRegressedChunk(16)
	}
	runtime.GC()

	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	if err := pprof.WriteHeapProfile(f); err != nil {
		return err
	}
	fmt.Printf("captured %s (chunks=%d+%d)\n", path, len(keepA), len(keepB))
	return nil
}

func main() {
	outDir := "demo/fixtures"
	if len(os.Args) > 1 {
		outDir = os.Args[1]
	}
	if err := captureCPU(filepath.Join(outDir, "baseline-cpu.pb.gz"), false); err != nil {
		panic(err)
	}
	if err := captureCPU(filepath.Join(outDir, "candidate-cpu.pb.gz"), true); err != nil {
		panic(err)
	}
	if err := captureHeap(filepath.Join(outDir, "baseline-heap.pb.gz"), false); err != nil {
		panic(err)
	}
	if err := captureHeap(filepath.Join(outDir, "candidate-heap.pb.gz"), true); err != nil {
		panic(err)
	}
}
