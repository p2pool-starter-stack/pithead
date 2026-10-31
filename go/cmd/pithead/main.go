package main

import (
	"errors"
	"fmt"
	"os"
	"os/signal"
	"path/filepath"
	"syscall"
	"time"

	"github.com/p2pool-starter-stack/pithead/go/internal/cli"
)

func main() {
	reference := os.Getenv("PITHEAD_GO_REFERENCE")
	if reference == "" {
		executable, err := os.Executable()
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		reference = filepath.Join(filepath.Dir(executable), "..", "..", "pithead")
	}
	if err := cli.Run(reference, os.Args[1:], os.Stdout); err != nil {
		var exitError *cli.ExitError
		if errors.As(err, &exitError) {
			if exitError.Signal != 0 {
				signal.Reset(exitError.Signal)
				_ = syscall.Kill(os.Getpid(), exitError.Signal)
				time.Sleep(100 * time.Millisecond)
			}
			if exitError.Message != "" {
				fmt.Fprintln(os.Stderr, err)
			}
			os.Exit(exitError.Code)
		}
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
