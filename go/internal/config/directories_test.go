package config

import (
	"errors"
	"testing"
)

func TestDeriveDirectoriesDefaults(t *testing.T) {
	want := DirectoryPlan{Values: [12]string{
		"/opt/pithead/data/monero",
		"/opt/pithead/data/tari",
		"/opt/pithead/data/p2pool",
		"/opt/pithead/data/tor",
		"/opt/pithead/data/dashboard",
		"1",
		"/opt/pithead/data/proxy-tls",
		"/opt/pithead/data/clearnet-state",
		"/opt/pithead/data/control",
		"/opt/pithead/data/caddy-logs",
		"/opt/pithead/data",
		"",
	}}
	got, err := DeriveDirectories([]byte(`{}`), "/opt/pithead")
	if err != nil || got != want {
		t.Fatalf("DeriveDirectories() = %#v, %v; want %#v, nil", got, err, want)
	}
}

func TestDeriveDirectoriesSharedAndScatteredRoots(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want DirectoryPlan
	}{
		{
			"shared",
			`{"monero":{"data_dir":"/mnt/pithead/monero"},"tari":{"data_dir":"/mnt/pithead/tari"},"p2pool":{"data_dir":"/mnt/pithead/p2pool"},"tor":{"data_dir":"/mnt/pithead/tor"}}`,
			DirectoryPlan{Values: [12]string{"/mnt/pithead/monero", "/mnt/pithead/tari", "/mnt/pithead/p2pool", "/mnt/pithead/tor", "/mnt/pithead/dashboard", "1", "/mnt/pithead/proxy-tls", "/opt/pithead/data/clearnet-state", "/opt/pithead/data/control", "/opt/pithead/data/caddy-logs", "/mnt/pithead", ""}},
		},
		{
			"scattered",
			`{"monero":{"data_dir":"/one/monero"},"tari":{"data_dir":"/two/tari"},"p2pool":{"data_dir":"/three/p2pool"},"tor":{"data_dir":"/four/tor"}}`,
			DirectoryPlan{Values: [12]string{"/one/monero", "/two/tari", "/three/p2pool", "/four/tor", "/opt/pithead/data/dashboard", "1", "/opt/pithead/data/proxy-tls", "/opt/pithead/data/clearnet-state", "/opt/pithead/data/control", "/opt/pithead/data/caddy-logs", "/opt/pithead/data", ""}},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := DeriveDirectories([]byte(test.raw), "/opt/pithead")
			if err != nil || got != test.want {
				t.Fatalf("DeriveDirectories() = %#v, %v; want %#v, nil", got, err, test.want)
			}
		})
	}
}

func TestDeriveDirectoriesPinnedDashboardAndSentinels(t *testing.T) {
	tests := []struct {
		name      string
		dashboard string
		wantDir   string
		wantFlag  string
	}{
		{"pinned", "/srv/dashboard", "/srv/dashboard", "0"},
		{"pinned default spelling", "/opt/pithead/data/dashboard", "/opt/pithead/data/dashboard", "0"},
		{"auto", "auto", "/opt/pithead/data/dashboard", "1"},
		{"legacy", "DYNAMIC_DATA", "/opt/pithead/data/dashboard", "1"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			raw := []byte(`{"dashboard":{"data_dir":"` + test.dashboard + `"}}`)
			got, err := DeriveDirectories(raw, "/opt/pithead")
			if err != nil || got.Values[4] != test.wantDir || got.Values[5] != test.wantFlag || got.Values[11] != test.dashboard {
				t.Fatalf("DeriveDirectories() = %#v, %v", got, err)
			}
		})
	}
}

func TestDeriveDirectoriesJQEmptyAndRootConcatenation(t *testing.T) {
	raw := []byte(`{"monero":{"data_dir":"/monero"},"tari":{"data_dir":"/tari"},"p2pool":{"data_dir":"/p2pool"},"tor":{"data_dir":"/tor"},"dashboard":{"data_dir":false}}`)
	got, err := DeriveDirectories(raw, "/opt/pithead")
	if err != nil {
		t.Fatalf("DeriveDirectories() error = %v", err)
	}
	if got.Values[4] != "//dashboard" || got.Values[5] != "1" || got.Values[6] != "//proxy-tls" || got.Values[10] != "/" || got.Values[11] != "" {
		t.Fatalf("DeriveDirectories() = %#v", got.Values)
	}
}

func TestDeriveDirectoriesPreservesUnsafeAbsolutePaths(t *testing.T) {
	raw := []byte(`{"monero":{"data_dir":"/srv//data/./../monero/"},"tari":{"data_dir":"/srv//data/./../tari/"},"p2pool":{"data_dir":"/srv//data/./../p2pool/"},"tor":{"data_dir":"/srv//data/./../tor/"},"dashboard":{"data_dir":"/srv/dashboard/"}}`)
	got, err := DeriveDirectories(raw, "/opt/./pithead")
	if err != nil {
		t.Fatalf("DeriveDirectories() error = %v", err)
	}
	if got.Values[0] != "/srv//data/./../monero/" || got.Values[4] != "/srv/dashboard/" || got.Values[7] != "/opt/./pithead/data/clearnet-state" {
		t.Fatalf("DeriveDirectories() normalized paths: %#v", got.Values)
	}
	if got.Values[10] != "/srv//data/./.." || got.Values[6] != "/srv//data/./../proxy-tls" {
		t.Fatalf("DeriveDirectories() root = %q, proxy = %q", got.Values[10], got.Values[6])
	}
}

func TestDeriveDirectoriesRejectsUnsupportedInput(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		cwd  string
	}{
		{"invalid JSON", `{`, "/opt/pithead"},
		{"duplicate", `{"monero":{},"monero":{}}`, "/opt/pithead"},
		{"compound", `{"monero":{"data_dir":[]}}`, "/opt/pithead"},
		{"control", `{"monero":{"data_dir":"/srv/\nmonero"}}`, "/opt/pithead"},
		{"relative", `{"monero":{"data_dir":"data/monero"}}`, "/opt/pithead"},
		{"option", `{"monero":{"data_dir":"-monero"}}`, "/opt/pithead"},
		{"double slash", `{"monero":{"data_dir":"//server/monero"}}`, "/opt/pithead"},
		{"relative cwd", `{}`, "opt/pithead"},
		{"double slash cwd", `{}`, "//opt/pithead"},
		{"control cwd", `{}`, "/opt/\npithead"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := DeriveDirectories([]byte(test.raw), test.cwd)
			if got != (DirectoryPlan{}) || !errors.Is(err, ErrUnsupportedValidation) {
				t.Fatalf("DeriveDirectories() = %#v, %v; want zero, unsupported", got, err)
			}
		})
	}
}
