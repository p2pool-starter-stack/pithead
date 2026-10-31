//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"testing"
)

func TestHostDependenciesParity(t *testing.T) {
	tests := []struct {
		name        string
		jq          bool
		openssl     bool
		docker      bool
		jqOutput    string
		jqExit      string
		dockOutput  string
		dockExit    string
		composeExit string
	}{
		{"missing", false, false, false, "", "0", "", "0", "0"},
		{"present", true, true, true, "jq-1.7\n", "0", "Docker version fixture\n", "0", "0"},
		{"version whitespace", true, true, true, "jq-fixture \n\n", "0", "Docker fixture \n\n", "0", "0"},
		{"jq version failure", true, true, true, "partial\n", "7", "Docker fixture\n", "0", "0"},
		{"docker version failure", true, true, true, "jq-fixture\n", "0", "partial\n", "9", "0"},
		{"compose failure", true, true, true, "jq-fixture\n", "0", "Docker fixture\n", "0", "11"},
	}
	for _, test := range tests {
		for _, appliance := range []bool{false, true} {
			t.Run(test.name+"/appliance="+boolName(appliance), func(t *testing.T) {
				dir := t.TempDir()
				log := filepath.Join(dir, "calls")
				dependencyTools(t, dir, test.jq, test.openssl, test.docker)
				t.Setenv("PATH", dir)
				t.Setenv("TOOL_LOG", log)
				t.Setenv("JQ_OUTPUT", test.jqOutput)
				t.Setenv("JQ_EXIT", test.jqExit)
				t.Setenv("DOCKER_OUTPUT", test.dockOutput)
				t.Setenv("DOCKER_EXIT", test.dockExit)
				t.Setenv("COMPOSE_EXIT", test.composeExit)

				result := runHostBash(t, "dependencies", appliance, filepath.Join(dir, "cpuinfo"), "Linux")
				bashCalls, err := os.ReadFile(log)
				if err != nil && !os.IsNotExist(err) {
					t.Fatal(err)
				}
				if err := os.WriteFile(log, nil, 0o600); err != nil {
					t.Fatal(err)
				}
				findings, err := Dependencies(appliance)
				if err != nil {
					t.Fatal(err)
				}
				assertHostFindings(t, result, findings)
				goCalls, err := os.ReadFile(log)
				if err != nil {
					t.Fatal(err)
				}
				if string(goCalls) != string(bashCalls) {
					t.Fatalf("Go calls %q, Bash calls %q", goCalls, bashCalls)
				}
			})
		}
	}
}

func TestHostDependenciesNULParity(t *testing.T) {
	dir := t.TempDir()
	dependencyTools(t, dir, true, true, true)
	writeHostTool(t, dir, "jq", "printf 'jq --version\\n' >>\"$TOOL_LOG\"\nprintf 'jq-fixture\\000tail\\n'\n")
	t.Setenv("PATH", dir)
	t.Setenv("TOOL_LOG", filepath.Join(dir, "calls"))
	t.Setenv("JQ_EXIT", "0")
	t.Setenv("DOCKER_EXIT", "0")
	t.Setenv("COMPOSE_EXIT", "0")
	result := runHostBash(t, "dependencies", false, filepath.Join(dir, "cpuinfo"), "Linux")
	findings, err := Dependencies(false)
	if !errors.Is(err, ErrUnsupportedProbeInput) || findings != nil {
		t.Fatalf("Dependencies() = %#v, %v", findings, err)
	}
	if result.code != 0 || result.stdout == "" || result.stderr == "" {
		t.Fatalf("Bash = exit %d, stdout %q, stderr %q", result.code, result.stdout, result.stderr)
	}
}

func dependencyTools(t *testing.T, dir string, jq, openssl, docker bool) {
	t.Helper()
	if jq {
		writeHostTool(t, dir, "jq", "printf 'jq %s\\n' \"$*\" >>\"$TOOL_LOG\"\nprintf '%s' \"$JQ_OUTPUT\"\nexit \"$JQ_EXIT\"\n")
	}
	if openssl {
		writeLoggedTool(t, dir, "openssl")
	}
	if docker {
		writeHostTool(t, dir, "docker", "printf 'docker %s\\n' \"$*\" >>\"$TOOL_LOG\"\nif [ \"${1:-}\" = --version ]; then printf '%s' \"$DOCKER_OUTPUT\"; exit \"$DOCKER_EXIT\"; fi\nif [ \"${1:-}\" = compose ] && [ \"${2:-}\" = version ]; then exit \"$COMPOSE_EXIT\"; fi\nexit 64\n")
	}
}

func boolName(value bool) string {
	if value {
		return "yes"
	}
	return "no"
}
