//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestControlUnitsReference(t *testing.T) {
	for _, state := range []string{"aligned", "foreign", "missing", "spool", "missing-path", "empty-spool", "disabled", "symlink", "deleted", "superseded", "live", "non-versioned", "broken-current", "directory-current", "Darwin", "missing-systemctl", "relative-units"} {
		for _, appliance := range []bool{false, true} {
			t.Run(state+"/"+boolName(appliance), func(t *testing.T) {
				fixture := newControlFixture(t)
				fixture.input.Appliance = appliance
				owner, spool := fixture.input.InstallDir, fixture.input.ControlDir
				switch state {
				case "foreign":
					owner = filepath.Join(fixture.input.InstallDir, "other")
					if err := os.Mkdir(owner, 0o700); err != nil {
						t.Fatal(err)
					}
				case "missing":
					owner = ""
				case "spool":
					spool += "-foreign"
				case "empty-spool":
					fixture.input.ControlDir = ""
				case "disabled":
					fixture.input.Enabled = "OFF"
				case "symlink":
					link := fixture.input.InstallDir + "-link"
					if err := os.Symlink(owner, link); err != nil {
						t.Fatal(err)
					}
					fixture.input.InstallDir = link
				case "deleted":
					owner += "/deleted/tree"
				case "superseded", "live", "non-versioned", "broken-current", "directory-current":
					parent := filepath.Dir(fixture.input.InstallDir)
					previous, live := filepath.Join(parent, "pithead-v1.2.3"), filepath.Join(parent, "pithead-v1.2.4")
					if state == "non-versioned" {
						previous = filepath.Join(parent, "rollback")
					}
					for _, dir := range []string{previous, live} {
						if err := os.Mkdir(dir, 0o700); err != nil {
							t.Fatal(err)
						}
					}
					fixture.input.InstallDir, owner = previous, live
					if state == "live" {
						fixture.input.InstallDir = live
					}
					current := filepath.Join(parent, "current")
					if state == "directory-current" {
						if err := os.Mkdir(current, 0o700); err != nil {
							t.Fatal(err)
						}
					} else {
						target := filepath.Base(live)
						if state == "broken-current" {
							target = "missing"
						}
						if err := os.Symlink(target, current); err != nil {
							t.Fatal(err)
						}
					}
				case "Darwin":
					fixture.input.OS = "Darwin"
				case "missing-systemctl":
					if err := os.Remove(filepath.Join(fixture.bin, "systemctl")); err != nil {
						t.Fatal(err)
					}
				case "relative-units":
					fixture.input.UnitDir = filepath.Join(fixture.input.InstallDir, "units")
				}
				if owner != "" {
					writeControlUnits(t, fixture.input.UnitDir, owner, spool)
				}
				if state == "missing-path" {
					if err := os.Remove(filepath.Join(fixture.input.UnitDir, "pithead-control.path")); err != nil {
						t.Fatal(err)
					}
				}
				if state == "relative-units" {
					fixture.input.UnitDir = "units"
				}
				result := fixture.reference(t, "control", fixture.input.Enabled, "", "")
				finding, section, err := fixture.input.Finding()
				if err != nil {
					t.Fatal(err)
				}
				assertControlFinding(t, result, finding, section)
			})
		}
	}
}

func TestControlRelativeTools(t *testing.T) {
	fixture := newControlFixture(t)
	writeControlUnits(t, fixture.input.UnitDir, fixture.input.InstallDir, fixture.input.ControlDir)
	bin := filepath.Join(fixture.input.InstallDir, "bin")
	if err := os.Rename(fixture.bin, bin); err != nil {
		t.Fatal(err)
	}
	fixture.bin = bin
	t.Setenv("PATH", "bin")
	t.Setenv("CONTROL_SYSTEMCTL_LOG", filepath.Join(bin, "calls"))
	result := fixture.reference(t, "control", "true", "", "")
	finding, _, err := fixture.input.Finding()
	if finding != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) || result.code != 0 || !strings.HasPrefix(result.stdout, "ok\t") {
		t.Fatalf("relative tools = %+v, %v; Bash %+v", finding, err, result)
	}
}

func TestControlEnabledReference(t *testing.T) {
	for _, enabled := range []string{"", "true", "TRUE", "yes", "1", "on", "false", "no", "0", "off", " true ", "true\n"} {
		fixture := newControlFixture(t)
		fixture.input.Enabled = enabled
		writeControlUnits(t, fixture.input.UnitDir, fixture.input.InstallDir, fixture.input.ControlDir)
		result := fixture.reference(t, "control", enabled, "", "")
		finding, section, err := fixture.input.Finding()
		if err != nil {
			t.Fatal(err)
		}
		assertControlFinding(t, result, finding, section)
	}
}

func TestControlDirectoryReference(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		for _, override := range []bool{false, true} {
			fixture := newControlFixture(t)
			fixture.input.Appliance = appliance
			if !override {
				fixture.input.UnitDir = ""
			}
			result := fixture.reference(t, "unit-dir", "", "", "")
			if got := ControlUnitDir(fixture.input.UnitDir, appliance); result.code != 0 || result.stderr != "" || got != result.stdout {
				t.Fatalf("directory = %q, Bash %+v", got, result)
			}
		}
	}
}

func TestControlOwnerReference(t *testing.T) {
	for _, content := range []string{
		"", "ExecStart=relative/pithead control-run-pending\n", " ExecStart=/fixture/pithead control-run-pending\n",
		"ExecStart=%s/pithead control-run-pending\n", "ExecStart=%s/deleted/tree/pithead control-run-pending\n",
		"ExecStart=%s/pithead control-run-pending\r\n", "ExecStart=%s/pithead control-run-pending\nExecStart=/second/pithead control-run-pending\n",
	} {
		fixture := newControlFixture(t)
		content = strings.ReplaceAll(content, "%s", fixture.input.InstallDir)
		if err := os.WriteFile(filepath.Join(fixture.input.UnitDir, "pithead-control.service"), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
		result := fixture.reference(t, "owner", "", "", "")
		owner, err := ControlUnitsOwnerDir(fixture.input.UnitDir, "", "")
		if err != nil || result.code != 0 || result.stderr != "" || result.stdout != owner {
			t.Fatalf("owner=%q, %v; Bash %+v", owner, err, result)
		}
	}
}

func TestControlOwnerEgress(t *testing.T) {
	fixture := newControlFixture(t)
	service, verb := "pithead-egress.service", "egress-run-pending"
	content := "ExecStart=" + fixture.input.InstallDir + "/pithead " + verb + "\n"
	if err := os.WriteFile(filepath.Join(fixture.input.UnitDir, service), []byte(content), 0o600); err != nil {
		t.Fatal(err)
	}
	result := fixture.reference(t, "owner", "", service, verb)
	owner, err := ControlUnitsOwnerDir(fixture.input.UnitDir, service, verb)
	if err != nil || result.code != 0 || result.stderr != "" || owner != result.stdout {
		t.Fatalf("egress owner=%q, %v; Bash %+v", owner, err, result)
	}
}

func TestControlOwnerUnsupported(t *testing.T) {
	fixture := newControlFixture(t)
	unit := filepath.Join(fixture.input.UnitDir, "pithead-control.service")
	if err := os.WriteFile(unit, []byte("ExecStart="+fixture.input.InstallDir+"\x00/pithead control-run-pending\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if finding, _, err := fixture.input.Finding(); finding != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("NUL unit = %+v, %v", finding, err)
	}
}
