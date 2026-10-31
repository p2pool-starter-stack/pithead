//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

var diskToolPaths = func() map[string]string {
	paths := make(map[string]string)
	for _, name := range []string{"awk", "dirname"} {
		paths[name], _ = exec.LookPath(name)
	}
	return paths
}()

type diskResponse struct {
	path, numeric, human   string
	numericExit, humanExit int
}

type diskFixture struct {
	input    Disk
	bin, log string
}

func newDiskFixture(t *testing.T) diskFixture {
	t.Helper()
	root := t.TempDir()
	fixture := diskFixture{Disk{Dir: filepath.Join(root, "install")}, filepath.Join(root, "bin"), filepath.Join(root, "calls")}
	for _, dir := range []string{fixture.input.Dir, fixture.bin} {
		if err := os.MkdirAll(dir, 0o700); err != nil {
			t.Fatal(err)
		}
	}
	for name, path := range diskToolPaths {
		if path == "" {
			t.Fatalf("%s missing", name)
		}
		if err := os.Symlink(path, filepath.Join(fixture.bin, name)); err != nil {
			t.Fatal(err)
		}
	}
	writeHostTool(t, fixture.bin, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, fixture.bin, "id", "printf 'fixture\\n'\n")
	t.Setenv("PATH", fixture.bin)
	t.Setenv("DISK_LOG", fixture.log)
	return fixture
}

func diskOutput(available, mount string) string {
	return "Filesystem 1024-blocks Used Available Capacity Mounted on\nfixture 9 9 " + available + " 1% " + mount + "\n"
}

func (fixture diskFixture) tools(t *testing.T, responses ...diskResponse) {
	t.Helper()
	var script strings.Builder
	script.WriteString("printf '%s|%s|%s|%s\\n' \"$PWD\" \"$#\" \"${1-}\" \"${2-}\" >>\"$DISK_LOG\"\ncase \"${2-}\" in\n")
	for _, response := range responses {
		fmt.Fprintf(&script, "%s)\ncase \"$1\" in\n-P) printf '%%b' %s; exit %d ;;\n-Ph) printf '%%b' %s; exit %d ;;\nesac ;;\n",
			diskQuote(response.path), diskOutputQuote(response.numeric), response.numericExit, diskOutputQuote(response.human), response.humanExit)
	}
	script.WriteString("esac\nprintf 'unexpected df call\\n' >&2\nexit 97\n")
	writeHostTool(t, fixture.bin, "df", script.String())
}

func diskQuote(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "'\\''") + "'"
}

func diskOutputQuote(value string) string {
	return diskQuote(strings.ReplaceAll(strings.ReplaceAll(value, "\\", "\\\\"), "\x00", "\\0000"))
}

func (fixture diskFixture) reference(t *testing.T, operation string, args ...string) hostBashResult {
	t.Helper()
	root := verificationRoot(t)
	commandArgs := []string{filepath.Join(root, "tests", "go-parity", "doctor_disk_reference.sh"), root, operation, fixture.input.Dir}
	command := exec.Command(hostParityBash, append(commandArgs, args...)...)
	command.Dir = fixture.input.Dir
	command.Env = append(hostEnvironment(t), "DISK_LOG="+fixture.log)
	var stdout, stderr bytes.Buffer
	command.Stdout, command.Stderr = &stdout, &stderr
	code := 0
	if err := command.Run(); err != nil {
		var status *exec.ExitError
		if !errors.As(err, &status) {
			t.Fatal(err)
		}
		code = status.ExitCode()
	}
	return hostBashResult{stdout.String(), stderr.String(), code}
}

func (fixture diskFixture) compare(t *testing.T, mode, prune string) {
	t.Helper()
	args := append([]string{mode, prune}, fixture.input.Dirs...)
	result := fixture.reference(t, "grouped", args...)
	calls := verificationCalls(t, fixture.log)
	resetVerificationCalls(t, fixture.log)
	findings, err := fixture.input.Check(mode)
	if err != nil {
		t.Fatal(err)
	}
	if mode == "doctor" {
		assertHostFindings(t, result, findings)
	} else {
		var human strings.Builder
		for _, finding := range findings {
			if finding.ID != "" || finding.Status != "warn" {
				t.Fatalf("unexpected preflight finding: %+v", finding)
			}
			human.WriteString("[WARNING] " + finding.Message + "\n")
		}
		if result.code != 0 || result.stdout != "" || result.stderr != human.String() {
			t.Fatalf("Bash %+v, Go warnings %q", result, human.String())
		}
	}
	if got := verificationCalls(t, fixture.log); got != calls {
		t.Fatalf("Go df calls %q, Bash calls %q", got, calls)
	}
}

func (fixture *diskFixture) dataDirs(t *testing.T) {
	t.Helper()
	for _, component := range []string{"monero", "tari", "p2pool", "dashboard", "tor"} {
		dir := filepath.Join(fixture.input.Dir, component)
		if err := os.Mkdir(dir, 0o700); err != nil {
			t.Fatal(err)
		}
		fixture.input.Dirs = append(fixture.input.Dirs, dir)
	}
}

func diskCapacity(path, mount string, gib int) diskResponse {
	return diskResponse{path: path, numeric: diskOutput(strconv.Itoa(gib*1048576), mount), human: diskOutput(strconv.Itoa(gib)+"G", mount)}
}
