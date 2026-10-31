//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestVerificationReleaseFindings(t *testing.T) {
	for _, state := range []string{"source", "source-link", "source-directory", "no-key", "key-directory", "key-link", "key-dangling", "missing-docker", "dead-docker", "cached", "uncached"} {
		for _, appliance := range []bool{false, true} {
			t.Run(state+"/"+boolName(appliance), func(t *testing.T) {
				dir, bin := t.TempDir(), t.TempDir()
				log := filepath.Join(bin, "calls")
				t.Setenv("PATH", bin)
				t.Setenv("PITHEAD_ENGINE", "podman")
				t.Setenv("TOOL_LOG", log)
				t.Setenv("VERIFICATION_INFO_EXIT", "0")
				t.Setenv("VERIFICATION_INSPECT_EXIT", "0")
				verificationTool(t, bin, "podman", true)
				if state != "missing-docker" {
					verificationTool(t, bin, "docker", true)
				}
				if state == "source" || state == "source-link" {
					file := filepath.Join(dir, "dashboard", "Dockerfile")
					verificationFile(t, file)
					if state == "source-link" {
						if err := os.Rename(file, file+".fixture"); err != nil {
							t.Fatal(err)
						}
						if err := os.Symlink("Dockerfile.fixture", file); err != nil {
							t.Fatal(err)
						}
					}
				}
				if state == "source-directory" {
					if err := os.MkdirAll(filepath.Join(dir, "dashboard", "Dockerfile"), 0o700); err != nil {
						t.Fatal(err)
					}
				}
				key := filepath.Join(dir, "cosign.pub")
				switch state {
				case "no-key", "source", "source-link":
				case "key-directory":
					if err := os.Mkdir(key, 0o700); err != nil {
						t.Fatal(err)
					}
				case "key-dangling":
					if err := os.Symlink("missing", key); err != nil {
						t.Fatal(err)
					}
				case "key-link":
					verificationFile(t, key+".fixture")
					if err := os.Symlink("cosign.pub.fixture", key); err != nil {
						t.Fatal(err)
					}
				default:
					verificationFile(t, key)
				}
				if state == "dead-docker" {
					t.Setenv("VERIFICATION_INFO_EXIT", "7")
				}
				if state == "uncached" {
					t.Setenv("VERIFICATION_INSPECT_EXIT", "9")
				}
				result := runVerificationBash(t, "release", appliance, dir, bin)
				calls := verificationCalls(t, log)
				resetVerificationCalls(t, log)
				finding, err := (ReleaseVerification{Dir: dir, Image: verificationImage(t), Appliance: appliance}).Finding()
				if err != nil {
					t.Fatal(err)
				}
				assertHostFindings(t, result, []Finding{finding})
				if got := verificationCalls(t, log); got != calls || strings.Contains(got, "podman") {
					t.Fatalf("Go calls %q, Bash calls %q", got, calls)
				}
			})
		}
	}
}

func TestVerificationDaemonFindings(t *testing.T) {
	for _, test := range []struct{ name, override, tools, exit string }{
		{"missing", "", "", "0"},
		{"docker", "", "docker", "0"},
		{"docker dead", "", "docker", "7"},
		{"podman", "", "podman", "0"},
		{"podman dead", "", "podman", "7"},
		{"both", "", "docker podman", "0"},
		{"override", "podman", "docker podman", "0"},
		{"missing docker override", "docker", "podman", "0"},
		{"missing podman override", "podman", "docker", "0"},
		{"invalid override", "invalid", "podman", "0"},
	} {
		for _, appliance := range []bool{false, true} {
			t.Run(test.name+"/"+boolName(appliance), func(t *testing.T) {
				dir, bin := t.TempDir(), t.TempDir()
				log := filepath.Join(bin, "calls")
				for _, name := range strings.Fields(test.tools) {
					verificationTool(t, bin, name, true)
				}
				t.Setenv("PATH", bin)
				t.Setenv("PITHEAD_ENGINE", test.override)
				t.Setenv("TOOL_LOG", log)
				t.Setenv("VERIFICATION_INFO_EXIT", test.exit)
				result := runVerificationBash(t, "daemon", appliance, dir, bin)
				calls := verificationCalls(t, log)
				resetVerificationCalls(t, log)
				finding, err := ContainerEngine(appliance)
				if err != nil {
					t.Fatal(err)
				}
				assertHostFindings(t, result, []Finding{finding})
				if got := verificationCalls(t, log); got != calls {
					t.Fatalf("Go calls %q, Bash calls %q", got, calls)
				}
			})
		}
	}
}

func TestVerificationUnsupportedLaunch(t *testing.T) {
	for _, operation := range []string{"daemon", "release"} {
		dir, bin := t.TempDir(), t.TempDir()
		verificationFile(t, filepath.Join(dir, "cosign.pub"))
		verificationTool(t, bin, "docker", false)
		t.Setenv("PATH", bin)
		t.Setenv("PITHEAD_ENGINE", "docker")
		result := runVerificationBash(t, operation, false, dir, bin)
		var got Finding
		var err error
		if operation == "release" {
			got, err = (ReleaseVerification{Dir: dir, Image: verificationImage(t)}).Finding()
		} else {
			got, err = ContainerEngine(false)
		}
		if result.code != 0 || !strings.HasPrefix(result.stdout, "ok\t") || got != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("%s: Bash %+v, Go %+v, %v", operation, result, got, err)
		}
	}
}

func TestVerificationRelativePath(t *testing.T) {
	for _, operation := range []string{"daemon", "release"} {
		cwd, err := os.Getwd()
		if err != nil {
			t.Fatal(err)
		}
		dir, bin := t.TempDir(), t.TempDir()
		verificationFile(t, filepath.Join(dir, "cosign.pub"))
		verificationTool(t, bin, "docker", false)
		path, err := filepath.Rel(cwd, bin)
		if err != nil {
			t.Fatal(err)
		}
		if operation == "release" {
			path = "."
			bin = dir
			verificationTool(t, bin, "docker", false)
		} else {
			dir = cwd
		}
		t.Setenv("PATH", path)
		t.Setenv("PITHEAD_ENGINE", "docker")
		result := runVerificationBash(t, operation, false, dir, bin)
		var finding Finding
		if operation == "release" {
			finding, err = (ReleaseVerification{Dir: dir, Image: verificationImage(t)}).Finding()
		} else {
			finding, err = ContainerEngine(false)
		}
		if result.code != 0 || !strings.HasPrefix(result.stdout, "ok\t") || finding != (Finding{}) || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("%s: Bash %+v, Go %+v, %v", operation, result, finding, err)
		}
	}
}
