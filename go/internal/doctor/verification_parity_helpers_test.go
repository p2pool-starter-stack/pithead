//go:build parity

package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"testing"
)

func verificationRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", "..", ".."))
	if err != nil {
		t.Fatal(err)
	}
	return root
}

func verificationImage(t *testing.T) string {
	t.Helper()
	source, err := os.ReadFile(filepath.Join(verificationRoot(t), "lib", "pithead", "03-release-verify.sh"))
	if err != nil {
		t.Fatal(err)
	}
	matches := regexp.MustCompile(`(?m)^readonly COSIGN_IMAGE="([^"]+)"`).FindAllSubmatch(source, -1)
	if len(matches) != 1 {
		t.Fatalf("expected one verifier pin, got %d", len(matches))
	}
	return string(matches[0][1])
}

func runVerificationBash(t *testing.T, operation string, appliance bool, dir, bin string) hostBashResult {
	t.Helper()
	writeHostTool(t, bin, "uname", "printf 'Linux\\n'\n")
	writeHostTool(t, bin, "id", "printf 'fixture\\n'\n")
	root := verificationRoot(t)
	surface := "0"
	if appliance {
		surface = "1"
	}
	command := exec.Command(hostParityBash, filepath.Join(root, "tests", "go-parity", "doctor_verification_reference.sh"), root, operation, surface, dir)
	command.Dir = dir
	command.Env = append(hostEnvironment(t), "VERIFICATION_INFO_EXIT="+os.Getenv("VERIFICATION_INFO_EXIT"), "VERIFICATION_INSPECT_EXIT="+os.Getenv("VERIFICATION_INSPECT_EXIT"))
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

func verificationTool(t *testing.T, bin, name string, shebang bool) {
	t.Helper()
	if !shebang {
		if err := os.WriteFile(filepath.Join(bin, name), []byte("exit 0\n"), 0o700); err != nil {
			t.Fatal(err)
		}
		return
	}
	writeHostTool(t, bin, name, "printf '"+name+"|%s|%s|%s|%s\\n' \"$#\" \"${1-}\" \"${2-}\" \"${3-}\" >>\"$TOOL_LOG\"\nprintf 'quiet stdout\\n'\nprintf 'quiet stderr\\n' >&2\ncase \"${1-}\" in info) exit \"$VERIFICATION_INFO_EXIT\" ;; image) exit \"$VERIFICATION_INSPECT_EXIT\" ;; *) exit 98 ;; esac\n")
}

func verificationCalls(t *testing.T, log string) string {
	t.Helper()
	calls, err := os.ReadFile(log)
	if err != nil && !os.IsNotExist(err) {
		t.Fatal(err)
	}
	return string(calls)
}

func resetVerificationCalls(t *testing.T, log string) {
	t.Helper()
	if err := os.WriteFile(log, nil, 0o600); err != nil {
		t.Fatal(err)
	}
}

func verificationFile(t *testing.T, path string) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, []byte("fixture\n"), 0o600); err != nil {
		t.Fatal(err)
	}
}
