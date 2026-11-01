package lifecycle

import (
	"errors"
	"reflect"
	"testing"
)

func TestParseOptions(t *testing.T) {
	tests := []struct {
		name    string
		verb    string
		args    []string
		want    Verdict
		wantErr error
	}{
		{"render", "render", nil, Verdict{Kind: "ok"}, nil},
		{"render argument", "render", []string{""}, Verdict{Kind: "unknown"}, nil},
		{"apply", "apply", []string{"-y", "--dry-run", "--porcelain", "--yes"}, Verdict{Kind: "ok", Options: Options{Yes: true, DryRun: true, Porcelain: true}}, nil},
		{"apply partial", "apply", []string{"--dry-run", "bad", "--yes"}, Verdict{Kind: "unknown", Argument: "bad", Options: Options{DryRun: true}}, nil},
		{"apply separator", "apply", []string{"--"}, Verdict{Kind: "unknown", Argument: "--"}, nil},
		{"apply porcelain", "apply", []string{"--porcelain"}, Verdict{Kind: "porcelain-needs-dry-run", Options: Options{Porcelain: true}}, nil},
		{"restart extras", "restart", []string{"tor", "ignored"}, Verdict{Kind: "ok"}, nil},
		{"restart empty", "restart", []string{"", "ignored"}, Verdict{Kind: "ok"}, nil},
		{"restart bad", "restart", []string{"all", "tor"}, Verdict{Kind: "unknown", Argument: "all"}, nil},
		{"unsupported", "upgrade", nil, Verdict{}, ErrUnsupported},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ParseOptions(test.verb, test.args)
			if !errors.Is(err, test.wantErr) || !reflect.DeepEqual(got, test.want) {
				t.Fatalf("got %#v, %v", got, err)
			}
		})
	}
}
