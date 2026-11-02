package lifecycle

import (
	"reflect"
	"testing"
)

func TestPlanKeepRunning(t *testing.T) {
	tests := []struct {
		name     string
		keep     string
		args     []string
		services []string
		want     []string
	}{
		{
			"scope",
			"tor monerod",
			[]string{"--remove-orphans", "--pull", "missing", "explicit"},
			[]string{"tor", "p2pool", "monerod"},
			[]string{"--pull", "--no-deps", "p2pool"},
		},
		{
			"literal whitespace",
			"tor\tmonerod\np2pool",
			nil,
			[]string{"tor", "monerod", "p2pool"},
			[]string{"--no-deps", "tor", "monerod", "p2pool"},
		},
		{
			"double space matches empty",
			"tor  monerod",
			[]string{"-"},
			[]string{"", "tor", "wallet", "wallet"},
			[]string{"-", "--no-deps", "wallet", "wallet"},
		},
		{
			"invalid bytes",
			"keep \xffname",
			[]string{"\xfeoption"},
			[]string{"\xffname", "\xfdservice"},
			[]string{"--no-deps", "\xfdservice"},
		},
		{
			"all kept",
			"tor tor",
			[]string{"--pull", "never"},
			[]string{"tor", "tor"},
			[]string{},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got := PlanKeepRunning(test.keep, test.args, test.services)
			if !reflect.DeepEqual(got, test.want) {
				t.Fatalf("got %#v, want %#v", got, test.want)
			}
		})
	}
}

func TestPlanKeepRunningReturnsIndependentSlice(t *testing.T) {
	args := []string{"--pull"}
	services := []string{"p2pool"}
	got := PlanKeepRunning("tor", args, services)
	got[0] = "changed"
	if args[0] != "--pull" || services[0] != "p2pool" {
		t.Fatalf("inputs changed: %#v %#v", args, services)
	}
}
