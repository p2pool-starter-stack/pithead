package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestControlUnitDir(t *testing.T) {
	if got := ControlUnitDir("", false); got != "/etc/systemd/system" {
		t.Fatal(got)
	}
	if got := ControlUnitDir("", true); got != "/run/systemd/system" {
		t.Fatal(got)
	}
	if got := ControlUnitDir("/custom", true); got != "/custom" {
		t.Fatal(got)
	}
}

func TestControlUnitsFinding(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	install := filepath.Join(root, "install")
	other := filepath.Join(root, "other")
	units := filepath.Join(root, "units")
	for _, dir := range []string{install, other, units} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	controlDir := filepath.Join(install, "data", "control")
	writeControlUnits(t, units, install, controlDir)
	base := ControlUnits{InstallDir: install, ControlDir: controlDir, UnitDir: units, Enabled: "true", OS: "Linux"}

	tests := []struct {
		name    string
		change  func(ControlUnits) ControlUnits
		status  string
		message string
		section bool
	}{
		{"aligned", func(c ControlUnits) ControlUnits { return c }, "ok", "Control runner units target this install.", true},
		{"disabled", func(c ControlUnits) ControlUnits { c.Enabled = "OFF"; return c }, "info", "Disabled for this install", true},
		{"non-linux", func(c ControlUnits) ControlUnits { c.OS = "Darwin"; return c }, "", "", false},
		{"foreign-owner", func(c ControlUnits) ControlUnits { writeControlUnits(t, units, other, controlDir); return c }, "fail", "units point at " + other, true},
		{"wrong-spool", func(c ControlUnits) ControlUnits {
			writeControlUnits(t, units, install, filepath.Join(other, "control"))
			return c
		}, "fail", "watches a different spool", true},
		{"empty-spool-skips-path", func(c ControlUnits) ControlUnits {
			c.ControlDir = ""
			writeControlUnits(t, units, install, "")
			return c
		}, "ok", "target this install", true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			writeControlUnits(t, units, install, controlDir)
			finding, section, err := test.change(base).Finding()
			if err != nil || section != test.section || finding.Status != test.status || !strings.Contains(finding.Message, test.message) {
				t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
			}
			if test.status != "" && finding.ID != "control-units" {
				t.Fatal(finding)
			}
		})
	}
}

func TestControlUnitsMissingAndApplianceMessages(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	install := filepath.Join(root, "install")
	units := filepath.Join(root, "units")
	if err := os.MkdirAll(install, 0o755); err != nil {
		t.Fatal(err)
	}
	control := ControlUnits{InstallDir: install, UnitDir: units, Enabled: "yes", OS: "Linux", Appliance: true}
	finding, section, err := control.Finding()
	if err != nil || !section || finding.Status != "fail" || !strings.Contains(finding.Message, "no runner units are installed") || !strings.Contains(finding.Message, "system copy is faulty") {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
}

func TestControlUnitsPhysicalAndDeletedOwner(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	version := filepath.Join(root, "versions", "pithead-v1.9.3")
	current := filepath.Join(root, "current")
	units := filepath.Join(root, "units")
	if err := os.MkdirAll(version, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(version, current); err != nil {
		t.Fatal(err)
	}
	writeControlUnits(t, units, version, "")
	finding, _, err := (ControlUnits{InstallDir: current, UnitDir: units, Enabled: "1", OS: "Linux"}).Finding()
	if err != nil || finding.Status != "ok" {
		t.Fatalf("finding=%+v err=%v", finding, err)
	}

	deleted := filepath.Join(root, "deleted", "tree")
	writeControlUnits(t, units, deleted, "")
	finding, _, err = (ControlUnits{InstallDir: version, UnitDir: units, Enabled: "on", OS: "Linux"}).Finding()
	if err != nil || finding.Status != "fail" || !strings.Contains(finding.Message, deleted) {
		t.Fatalf("finding=%+v err=%v", finding, err)
	}
}

func TestControlUnitsSupersededInstall(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	old := filepath.Join(root, "pithead-v1.19.0")
	live := filepath.Join(root, "pithead-v1.19.1")
	units := filepath.Join(root, "units")
	for _, dir := range []string{old, live} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Base(live), filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	writeControlUnits(t, units, live, "")
	finding, section, err := (ControlUnits{InstallDir: old, UnitDir: units, Enabled: "true", OS: "Linux"}).Finding()
	if err != nil || !section || finding.Status != "info" || !strings.Contains(finding.Message, live) {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
	finding, _, err = (ControlUnits{InstallDir: live, UnitDir: units, Enabled: "true", OS: "Linux"}).Finding()
	if err != nil || finding.Status != "ok" {
		t.Fatalf("finding=%+v err=%v", finding, err)
	}
}

func TestControlUnitsSupersededInstallReadsOwnerFirst(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	old := filepath.Join(root, "pithead-v2.0.0")
	live := filepath.Join(root, "pithead-v2.0.1")
	units := filepath.Join(root, "units")
	for _, dir := range []string{old, live, units} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	if err := os.Symlink(filepath.Base(live), filepath.Join(root, "current")); err != nil {
		t.Fatal(err)
	}
	service := filepath.Join(units, "pithead-control.service")
	if err := os.WriteFile(service, []byte("ExecStart=/bad\x00/pithead control-run-pending\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	control := ControlUnits{InstallDir: old, UnitDir: units, Enabled: "true", OS: "Linux"}
	if finding, section, err := control.Finding(); finding != (Finding{}) || !section || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
}

func TestControlUnitsOwnerDirParsing(t *testing.T) {
	root := t.TempDir()
	units := filepath.Join(root, "units")
	owner := filepath.Join(root, "owner")
	if err := os.MkdirAll(filepath.Join(owner, "real"), 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(owner, "link")
	if err := os.Symlink("real", link); err != nil {
		t.Fatal(err)
	}
	if err := os.MkdirAll(units, 0o755); err != nil {
		t.Fatal(err)
	}
	content := "ExecStart=relative/pithead control-run-pending\nExecStart=" + link + "/missing/pithead egress-run-pending\n"
	if err := os.WriteFile(filepath.Join(units, "egress.service"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	got, err := ControlUnitsOwnerDir(units, "egress.service", "egress-run-pending")
	want := filepath.Join(owner, "real", "missing")
	if err != nil || got != want {
		t.Fatalf("got=%q want=%q err=%v", got, want, err)
	}
}

func TestControlUnitsUnsupportedInputs(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	units := filepath.Join(root, "units")
	if err := os.MkdirAll(units, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(units, "pithead-control.service"), []byte("ExecStart=/tmp\x00/pithead control-run-pending\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := ControlUnitsOwnerDir(units, "", ""); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("got=%q err=%v", got, err)
	}
	writeControlUnits(t, units, root, root)
	if err := os.WriteFile(filepath.Join(units, "pithead-control.path"), []byte("PathExistsGlob="+root+"\x00/requests/*.json\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if finding, section, err := (ControlUnits{InstallDir: root, ControlDir: root, UnitDir: units, Enabled: "true", OS: "Linux"}).Finding(); finding != (Finding{}) || !section || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
	control := ControlUnits{InstallDir: root + "\x00", Enabled: "true", OS: "Linux"}
	if finding, section, err := control.Finding(); finding != (Finding{}) || !section || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
}

func TestControlUnitsSymlinkParentPathFallsBack(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	target := filepath.Join(root, "target", "child")
	units := filepath.Join(root, "units")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(root, "link")
	if err := os.Symlink(target, link); err != nil {
		t.Fatal(err)
	}
	path := link + string(filepath.Separator) + ".."
	writeControlUnits(t, units, path, "")
	if owner, err := ControlUnitsOwnerDir(units, "", ""); owner != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("owner=%q err=%v", owner, err)
	}
	control := ControlUnits{InstallDir: path, UnitDir: units, Enabled: "true", OS: "Linux"}
	if finding, section, err := control.Finding(); finding != (Finding{}) || !section || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
	if owner, err := ControlUnitsOwnerDir(units, "", "control.run*"); owner != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("owner=%q err=%v", owner, err)
	}
}

func TestControlUnitsSystemctlGate(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	finding, section, err := (ControlUnits{OS: "Linux"}).Finding()
	if err != nil || section || finding != (Finding{}) {
		t.Fatalf("finding=%+v section=%v err=%v", finding, section, err)
	}
}

func installSystemctl(t *testing.T, root string) {
	t.Helper()
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(bin, "systemctl"), []byte("#!/bin/sh\nexit 99\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", bin)
}

func writeControlUnits(t *testing.T, unitDir, owner, spool string) {
	t.Helper()
	if err := os.MkdirAll(unitDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(unitDir, "pithead-control.service"), []byte("[Service]\nExecStart="+owner+"/pithead control-run-pending\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	path := "[Path]\n"
	if spool != "" {
		path += "PathExistsGlob=" + spool + "/requests/*.json\n"
	}
	if err := os.WriteFile(filepath.Join(unitDir, "pithead-control.path"), []byte(path), 0o644); err != nil {
		t.Fatal(err)
	}
}
