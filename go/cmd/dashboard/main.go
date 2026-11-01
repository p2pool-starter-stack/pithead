package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/charts"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/runtime"
)

func main() {
	if helper := os.Getenv("PITHEAD_DASHBOARD_HELPER"); helper != "" {
		if helper != "chart" || charts.Run(os.Stdin, os.Stdout) != nil {
			os.Exit(125)
		}
		return
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	if err := runtime.Run(ctx, os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
