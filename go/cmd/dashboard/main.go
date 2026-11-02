package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/badges"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/charts"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/control"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/controlhttp"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/fleet"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/infra"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/network"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/overview"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/resources"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/runtime"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/series"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/stateview"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/storage"
	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"
)

func main() {
	if helper := os.Getenv("PITHEAD_DASHBOARD_HELPER"); helper != "" {
		var err error
		switch helper {
		case "control":
			err = control.Run(os.Stdin, os.Stdout)
		case "control-http":
			err = controlhttp.Run(os.Stdin, os.Stdout)
		case "wizard":
			err = wizard.Run(os.Stdin, os.Stdout)
		case "wizard-write":
			err = wizard.RunWrite(os.Stdin, os.Stdout)
		case "wizard-auth":
			err = wizard.RunAuth(os.Stdin, os.Stdout)
		case "wizard-form":
			err = wizard.RunForm(os.Stdin, os.Stdout)
		case "wizard-config":
			err = wizard.RunConfig(os.Stdin, os.Stdout)
		case "wizard-preparation":
			err = wizard.RunPreparation(os.Stdin, os.Stdout)
		case "wizard-state":
			err = wizard.RunState(os.Stdin, os.Stdout)
		case "wizard-values":
			err = wizard.RunValues(os.Stdin, os.Stdout)
		case "documents":
			err = wizard.RunDocuments(os.Stdin, os.Stdout)
		case "wizard-terminal":
			err = wizard.RunTerminal(os.Stdin, os.Stdout)
		case "wizard-submission":
			err = wizard.RunSubmission(os.Stdin, os.Stdout)
		case "wizard-typed":
			err = wizard.RunTypedSubmission(os.Stdin, os.Stdout)
		case "storage":
			err = storage.Run(os.Stdin, os.Stdout)
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
		case "network":
			err = network.Run(os.Stdin, os.Stdout)
		case "network-stream":
			err = network.RunStream(os.Stdin, os.Stdout)
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
		case "state":
			err = stateview.Run(os.Stdin, os.Stdout)
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
