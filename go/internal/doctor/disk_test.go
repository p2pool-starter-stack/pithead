package doctor

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func TestDiskComponentGiB(t *testing.T) {
	want := map[string]int64{"monero": 320, "tari": 200, "p2pool": 5, "dashboard": 2, "tor": 1, "unknown": 0}
	for component, expected := range want {
		if got := DiskComponentGiB(component); got != expected {
			t.Errorf("DiskComponentGiB(%q) = %d, want %d", component, got, expected)
		}
	}
}

func TestDiskInteger(t *testing.T) {
	for input, want := range map[string]int64{"553648128\r": 553648128, "\v+0008\f": 8, " -1 ": -1} {
		if got, ok := diskInteger(input); !ok || got != want {
			t.Errorf("diskInteger(%q) = %d, %t, want %d, true", input, got, ok, want)
		}
	}
	for _, input := range []string{"", "not-a-number", "9223372036854775808"} {
		if got, ok := diskInteger(input); ok {
			t.Errorf("diskInteger(%q) = %d, %t, want false", input, got, ok)
		}
	}
}

func TestDiskCheckGroupsFilesystems(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	dirs := fixture.dataDirs(t)
	t.Setenv("DISK_BIG_DIRS", strings.Join(dirs[:2], ":"))
	t.Setenv("DISK_AVAIL_KB", "629145600")
	t.Setenv("DISK_AVAIL_H", "600G")
	findings, err := (Disk{Dir: fixture.root, Dirs: dirs}).Check("doctor")
	if err != nil {
		t.Fatal(err)
	}
	want := []Finding{
		{"disk-space", "ok", "Data on /big (monero, tari): 600G free — needs ~520 GiB."},
		{"disk-space", "ok", "Data on /small (p2pool, dashboard, tor): 600G free — needs ~8 GiB."},
	}
	if len(findings) != len(want) {
		t.Fatalf("findings = %+v", findings)
	}
	for index := range want {
		if findings[index] != want[index] {
			t.Errorf("finding %d = %+v, want %+v", index, findings[index], want[index])
		}
	}
	calls, err := os.ReadFile(fixture.log)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(calls), "-Ph ") != 2 || strings.Count(string(calls), "-P /big") != 1 || strings.Count(string(calls), "-P /small") != 1 {
		t.Fatalf("df calls = %q", calls)
	}
}

func TestDiskCheckPreflight(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	dirs := fixture.dataDirs(t)
	t.Setenv("DISK_BIG_DIRS", strings.Join(dirs, ":"))
	t.Setenv("DISK_AVAIL_KB", "104857600")
	t.Setenv("DISK_AVAIL_H", "100G")
	disk := Disk{Dir: fixture.root, Dirs: dirs}
	findings, err := disk.Check("preflight")
	if err != nil || len(findings) != 1 {
		t.Fatalf("low findings = %+v, %v", findings, err)
	}
	want := "Low disk on /big (hosts monero, tari, p2pool, dashboard, tor): 100G free, below the ~528 GiB the stack needs there — free space or move a data_dir to a larger volume."
	if findings[0] != (Finding{"", "warn", want}) {
		t.Fatalf("low finding = %+v", findings[0])
	}
	t.Setenv("DISK_AVAIL_KB", "629145600")
	if findings, err = disk.Check("anything"); err != nil || findings != nil {
		t.Fatalf("ample findings = %+v, %v", findings, err)
	}
}

func TestDiskBackslashHumanValue(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	dirs := fixture.dataDirs(t)
	t.Setenv("DISK_BIG_DIRS", strings.Join(dirs, ":"))
	t.Setenv("DISK_AVAIL_H", `600\G`)
	disk := Disk{Dir: fixture.root, Dirs: dirs}
	findings, err := disk.Check("doctor")
	if err != nil || len(findings) != 1 || !strings.Contains(findings[0].Message, `600\G free`) {
		t.Fatalf("doctor = %+v, %v", findings, err)
	}
	if findings, err = disk.Check("preflight"); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("preflight = %+v, %v", findings, err)
	}
}

func TestDiskMountWalksToExistingAncestor(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	missing := filepath.Join(fixture.root, "data", "fresh", "monero")
	t.Setenv("DISK_BIG_DIRS", filepath.Join(fixture.root, "data"))
	mount, err := (Disk{Dir: fixture.root}).Mount(missing)
	if err != nil || mount != "/big" {
		t.Fatalf("Mount = %q, %v", mount, err)
	}
	calls, err := os.ReadFile(fixture.log)
	if err != nil {
		t.Fatal(err)
	}
	if string(calls) != "-P "+filepath.Join(fixture.root, "data")+"\n" {
		t.Fatalf("df calls = %q", calls)
	}
}

func TestDiskCheckUnresolved(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	dirs := fixture.dataDirs(t)
	t.Setenv("DISK_FAIL_ALL", "1")
	findings, err := (Disk{Dir: fixture.root, Dirs: dirs}).Check("doctor")
	if err != nil || len(findings) != 1 || findings[0] != (Finding{"disk-space", "info", "No data dirs resolved to a filesystem — skipping disk check."}) {
		t.Fatalf("findings = %+v, %v", findings, err)
	}
	if findings, err = (Disk{Dir: fixture.root, Dirs: dirs}).Check("preflight"); err != nil || findings != nil {
		t.Fatalf("preflight = %+v, %v", findings, err)
	}
}

func TestDiskCheckCapacityFailure(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	dirs := fixture.dataDirs(t)
	t.Setenv("DISK_BIG_DIRS", strings.Join(dirs, ":"))
	t.Setenv("DISK_FAIL_MOUNT", "1")
	if findings, err := (Disk{Dir: fixture.root, Dirs: dirs}).Check("doctor"); findings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("findings = %+v, %v", findings, err)
	}
}

func TestDiskRejectsUnsupportedInputs(t *testing.T) {
	fixture := newUnitDiskFixture(t)
	abs := filepath.Join(fixture.root, "data")
	tests := []struct {
		name string
		disk Disk
		path string
	}{
		{"relative workdir", Disk{Dir: "."}, abs},
		{"parent workdir", Disk{Dir: fixture.root + "/data/.."}, abs},
		{"parent path", Disk{Dir: fixture.root}, fixture.root + "/data/../data"},
		{"nul path", Disk{Dir: fixture.root}, abs + "\x00x"},
		{"newline path", Disk{Dir: fixture.root}, abs + "\nx"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			if mount, err := test.disk.Mount(test.path); mount != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("Mount = %q, %v", mount, err)
			}
		})
	}
	t.Setenv("PATH", "relative")
	if mount, err := (Disk{Dir: fixture.root}).Mount(abs); mount != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("relative PATH Mount = %q, %v", mount, err)
	}
}

func TestDiskRequiresReferenceTools(t *testing.T) {
	for _, missing := range []string{"awk", "dirname"} {
		t.Run(missing, func(t *testing.T) {
			fixture := newUnitDiskFixture(t)
			bin := t.TempDir()
			for _, tool := range []string{"df", "awk", "dirname"} {
				if tool == missing {
					continue
				}
				if err := os.Symlink(filepath.Join(fixture.bin, tool), filepath.Join(bin, tool)); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("PATH", bin)
			path := filepath.Join(fixture.root, "data")
			if missing == "dirname" {
				path = filepath.Join(path, "fresh", "monero")
			}
			if mount, err := (Disk{Dir: fixture.root}).Mount(path); mount != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("Mount = %q, %v", mount, err)
			}
		})
	}
}

func TestDiskRejectsBrokenReferenceTools(t *testing.T) {
	for _, name := range []string{"awk failure", "awk no shebang", "dirname failure", "dirname no shebang"} {
		t.Run(name, func(t *testing.T) {
			fixture := newUnitDiskFixture(t)
			bin := t.TempDir()
			brokenTool := strings.Fields(name)[0]
			for _, tool := range []string{"df", "awk", "dirname"} {
				if tool != brokenTool {
					if err := os.Symlink(filepath.Join(fixture.bin, tool), filepath.Join(bin, tool)); err != nil {
						t.Fatal(err)
					}
					continue
				}
				body := "exit 7\n"
				if strings.HasSuffix(name, "failure") {
					body = "#!/bin/sh\n" + body
				}
				if err := os.WriteFile(filepath.Join(bin, tool), []byte(body), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			t.Setenv("PATH", bin)
			path := filepath.Join(fixture.root, "data")
			if brokenTool == "dirname" {
				path = filepath.Join(path, "fresh")
			}
			if mount, err := (Disk{Dir: fixture.root}).Mount(path); mount != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
				t.Fatalf("Mount = %q, %v", mount, err)
			}
		})
	}
}

type unitDiskFixture struct {
	root string
	bin  string
	log  string
}

func newUnitDiskFixture(t *testing.T) unitDiskFixture {
	t.Helper()
	root := t.TempDir()
	bin := filepath.Join(root, "bin")
	if err := os.MkdirAll(filepath.Join(root, "data"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Mkdir(bin, 0o755); err != nil {
		t.Fatal(err)
	}
	tool := `#!/bin/sh
printf '%s %s\n' "$1" "$2" >>"$DISK_LOG"
[ "$DISK_FAIL_ALL" = 1 ] && exit 1
case ":$DISK_BIG_DIRS:" in *":$2:"*) mount=/big ;; *) mount=/small ;; esac
[ "$DISK_FAIL_MOUNT" = 1 ] && { [ "$2" = /big ] || [ "$2" = /small ]; } && exit 1
printf '%s\n' 'Filesystem 1024-blocks Used Available Capacity Mounted on'
if [ "$1" = -Ph ]; then
  printf 'src 9 9 %s 1%% %s\n' "${DISK_AVAIL_H:-600G}" "$mount"
else
  printf 'src 9 9 %s 1%% %s\n' "${DISK_AVAIL_KB:-629145600}" "$mount"
fi
`
	if err := os.WriteFile(filepath.Join(bin, "df"), []byte(tool), 0o700); err != nil {
		t.Fatal(err)
	}
	for _, name := range []string{"awk", "dirname"} {
		path, err := exec.LookPath(name)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(path, filepath.Join(bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	log := filepath.Join(root, "calls")
	t.Setenv("PATH", bin)
	t.Setenv("DISK_LOG", log)
	return unitDiskFixture{root: root, bin: bin, log: log}
}

func (fixture unitDiskFixture) dataDirs(t *testing.T) []string {
	t.Helper()
	dirs := make([]string, len(diskComponents))
	for index, component := range diskComponents {
		dirs[index] = filepath.Join(fixture.root, "data", component)
		if err := os.Mkdir(dirs[index], 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dirs
}
