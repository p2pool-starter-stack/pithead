package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"testing"
)

func TestDataDirectoriesMissingAndFindings(t *testing.T) {
	root := t.TempDir()
	monero := filepath.Join(root, "monero")
	tari := filepath.Join(root, "tari")
	if err := os.Mkdir(monero, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(monero, tari); err != nil {
		t.Fatal(err)
	}
	file := filepath.Join(root, "p2pool")
	if err := os.WriteFile(file, []byte("not a directory"), 0o644); err != nil {
		t.Fatal(err)
	}
	data := DataDirectories{
		Dir:       root,
		Completed: "true\n\n",
		Dirs:      []string{"monero", tari, file, "missing/.", "", filepath.Join(root, "ignored")},
	}
	wantMissing := []string{"P2POOL_DATA_DIR=" + file, "DASHBOARD_DATA_DIR=missing/."}
	missing, err := data.Missing()
	if err != nil || !reflect.DeepEqual(missing, wantMissing) {
		t.Fatalf("Missing() = %#v, %v; want %#v", missing, err, wantMissing)
	}
	findings, err := data.Findings()
	if err != nil || len(findings) != 2 {
		t.Fatalf("Findings() = %#v, %v", findings, err)
	}
	if findings[0] != (Finding{"data-directories", "warn", "Data dir from .env not found: P2POOL_DATA_DIR=" + file + " — a relocated/copied install re-syncs from scratch. Move the data here, or set the data_dir in config.json and run 'apply'."}) {
		t.Fatalf("first finding = %#v", findings[0])
	}
	data.Appliance = true
	findings, err = data.Findings()
	if err != nil || findings[0] != (Finding{"data-directories", "warn", "Data dir from .env not found: P2POOL_DATA_DIR=" + file + " — this machine re-syncs that data from scratch, and the dashboard history recorded against it is orphaned. With the dashboard control channel on, all five data dirs can be repointed from Configuration behind its confirmation step. Moving existing data back is not a dashboard action and needs console access to this machine."}) {
		t.Fatalf("appliance finding = %#v, %v", findings, err)
	}
}

func TestDataDirectoriesPresentAndPredeployment(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"monero", "tari", "p2pool", "dashboard", "tor"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	dirs := []string{"monero", "tari", "p2pool", "dashboard", "tor"}
	data := DataDirectories{Dir: root, Completed: "true", Dirs: dirs}
	if missing, err := data.Missing(); err != nil || missing != nil {
		t.Fatalf("Missing() = %#v, %v", missing, err)
	}
	want := []Finding{{"data-directories", "ok", "Data directories named in .env are present."}}
	if findings, err := data.Findings(); err != nil || !reflect.DeepEqual(findings, want) {
		t.Fatalf("Findings() = %#v, %v; want %#v", findings, err, want)
	}
	predeploy := DataDirectories{Dir: "relative", Completed: "false", Dirs: []string{"../unsafe"}}
	if missing, err := predeploy.Missing(); err != nil || missing != nil {
		t.Fatalf("predeploy Missing() = %#v, %v", missing, err)
	}
	if findings, err := predeploy.Findings(); err != nil || findings != nil {
		t.Fatalf("predeploy Findings() = %#v, %v", findings, err)
	}
}

func TestDataDirectoriesWarnings(t *testing.T) {
	root := t.TempDir()
	data := DataDirectories{Dir: root, Completed: "true", Dirs: []string{"one", "", "three"}}
	want := []string{
		"Data directories named in .env are MISSING — did you relocate, copy, or run a different checkout of this install?",
		"  MONERO_DATA_DIR → one (not found)",
		"  P2POOL_DATA_DIR → three (not found)",
		"The stack will start a FRESH sync and the dashboard history will be orphaned. To keep your synced chains,",
		"move the data to these paths, or set the data_dir(s) in config.json (absolute) and run './pithead apply'.",
	}
	if warnings, err := data.Warnings(); err != nil || !reflect.DeepEqual(warnings, want) {
		t.Fatalf("Warnings() = %#v, %v; want %#v", warnings, err, want)
	}
	data.Dirs[0] = `missing\name`
	if warnings, err := data.Warnings(); warnings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("backslash Warnings() = %#v, %v", warnings, err)
	}
	if missing, err := data.Missing(); err != nil || !reflect.DeepEqual(missing, []string{`MONERO_DATA_DIR=missing\name`, "P2POOL_DATA_DIR=three"}) {
		t.Fatalf("backslash Missing() = %#v, %v", missing, err)
	}
}

func TestDataDirectoriesRejectUnsupportedInputs(t *testing.T) {
	root := t.TempDir()
	cases := []DataDirectories{
		{Dir: "relative", Completed: "true"},
		{Dir: root + "/../" + filepath.Base(root), Completed: "true"},
		{Dir: root, Completed: "true\x00"},
		{Dir: root, Completed: "true", Dirs: []string{"../missing"}},
		{Dir: root, Completed: "true", Dirs: []string{"missing\rpath"}},
		{Dir: root, Completed: "true", Dirs: []string{"missing\npath"}},
	}
	for _, data := range cases {
		if missing, err := data.Missing(); missing != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Errorf("Missing(%#v) = %#v, %v", data, missing, err)
		}
	}
}
