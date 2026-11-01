package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/badges"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/charts"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/fleet"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/infra"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/overview"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/resources"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/runtime"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/series"
)

func main() {
	if helper := os.Getenv("PITHEAD_DASHBOARD_HELPER"); helper != "" {
		var err error
		switch helper {
		case "chart":
			err = charts.Run(os.Stdin, os.Stdout)
		case "domain":
			err = domain.Run(os.Stdin, os.Stdout)
		case "average":
			err = domain.RunAverage(os.Stdin, os.Stdout)
		case "average-stream":
			err = domain.RunAverageStream(os.Stdin, os.Stdout)
		case "infra":
			err = infra.Run(os.Stdin, os.Stdout)
		case "series":
			err = series.Run(os.Stdin, os.Stdout)
		case "fleet":
			err = fleet.Run(os.Stdin, os.Stdout)
		case "resources":
			err = resources.Run(os.Stdin, os.Stdout)
		case "fleet-stream":
			err = streamHelper(fleet.Run, os.Stdin, os.Stdout)
		case "resources-stream":
			err = streamHelper(resources.Run, os.Stdin, os.Stdout)
		case "overview":
			err = overview.Run(os.Stdin, os.Stdout)
		case "overview-stream":
			err = streamHelper(overview.Run, os.Stdin, os.Stdout)
		case "badges":
			err = badges.Run(os.Stdin, os.Stdout)
		case "badges-stream":
			err = streamHelper(badges.Run, os.Stdin, os.Stdout)
		default:
			os.Exit(125)
		}
		if err != nil {
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
