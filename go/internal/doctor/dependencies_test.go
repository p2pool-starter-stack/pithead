package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestDependencies(t *testing.T) {
	for _, appliance := range []bool{false, true} {
		t.Run(map[bool]string{false: "diy", true: "appliance"}[appliance], func(t *testing.T) {
			dir := fakeDependencyTools(t)
			findings, err := Dependencies(appliance)
			if err != nil || len(findings) != 4 {
				t.Fatalf("Dependencies = %+v, %v", findings, err)
			}
			for index, name := range []string{"jq", "openssl", "docker", "compose"} {
				if findings[index].ID != "dependency-"+name || findings[index].Status != "ok" {
					t.Fatalf("dependency order/status = %+v", findings)
				}
			}
			if findings[0].Message != "jq found (jq fixture)." || findings[2].Message != "docker found (docker fixture)." {
				t.Fatalf("versions = %+v", findings)
			}
			if err := os.Remove(filepath.Join(dir, "docker")); err != nil {
				t.Fatal(err)
			}
			findings, err = Dependencies(appliance)
			if err != nil || findings[2].Status != "fail" || findings[3].Status != "fail" || strings.Contains(findings[2].Message, "system copy") != appliance {
				t.Fatalf("missing Docker = %+v, %v", findings, err)
			}
		})
	}
}

func TestDependencyVersionFailure(t *testing.T) {
	fakeDependencyTools(t)
	for _, output := range []string{"", "partial", "partial\n"} {
		t.Run(output, func(t *testing.T) {
			t.Setenv("DEP_OUTPUT", output)
			t.Setenv("DEP_EXIT", "7")
			got, err := toolVersion("jq")
			want := strings.TrimRight(output+"unknown version\n", "\n")
			if err != nil || got != want {
				t.Fatalf("version = %q, %v; want %q", got, err, want)
			}
		})
	}
}

func TestDependencyUnsupportedVersion(t *testing.T) {
	dir := fakeDependencyTools(t)
	if err := os.WriteFile(filepath.Join(dir, "jq"), []byte("#!/bin/sh\nprintf 'jq\\000version\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := Dependencies(false); !errors.Is(err, ErrUnsupportedProbeInput) || got != nil {
		t.Fatalf("NUL version = %+v, %v", got, err)
	}
	if err := os.WriteFile(filepath.Join(dir, "jq"), []byte("printf 'jq-version\\n'\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	if got, err := Dependencies(false); !errors.Is(err, ErrUnsupportedProbeInput) || got != nil {
		t.Fatalf("shell fallback = %+v, %v", got, err)
	}
}

func fakeDependencyTools(t *testing.T) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range map[string]string{
		"jq":      "printf '%s' \"$DEP_OUTPUT\"\nexit \"$DEP_EXIT\"\n",
		"openssl": "exit 99\n",
		"docker":  "case \"$*\" in '--version') printf 'docker fixture\\n' ;; 'compose version') exit 0 ;; *) exit 99 ;; esac\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("#!/bin/sh\n"+body), 0o700); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("DEP_OUTPUT", "jq fixture\n")
	t.Setenv("DEP_EXIT", "0")
	t.Setenv("PATH", dir)
	return dir
}
