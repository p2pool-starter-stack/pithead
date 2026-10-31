//go:build parity

package doctor

import (
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

func TestDataDirectoryStates(t *testing.T) {
	for _, state := range []string{"missing", "present", "files", "directory links", "file links", "dangling", "mixed"} {
		for _, appliance := range []bool{false, true} {
			t.Run(state+"/"+boolName(appliance), func(t *testing.T) {
				fixture := newDataDirectoriesFixture(t)
				fixture.input.Appliance = appliance
				for i := 0; i < 5; i++ {
					path := filepath.Join(fixture.input.Dir, "data"+strconv.Itoa(i))
					fixture.input.Dirs = append(fixture.input.Dirs, path)
					switch state {
					case "present", "directory links":
						if err := os.Mkdir(path, 0o700); err != nil {
							t.Fatal(err)
						}
					case "files", "file links":
						verificationFile(t, path)
					case "mixed":
						if i%2 == 0 {
							if err := os.Mkdir(path, 0o700); err != nil {
								t.Fatal(err)
							}
						}
					}
					if strings.HasSuffix(state, "links") || state == "dangling" {
						if err := os.Symlink(path, path+"-link"); err != nil {
							t.Fatal(err)
						}
						fixture.input.Dirs[i] += "-link"
					}
				}
				for _, operation := range []string{"missing", "findings", "warnings"} {
					fixture.compare(t, operation)
				}
			})
		}
	}
}

func TestDataDirectoryCompletionGate(t *testing.T) {
	for _, completed := range []string{"", "false", "TRUE", "yes", "1", "true ", "true\r", "true\n\n", "true"} {
		t.Run(strconv.Quote(completed), func(t *testing.T) {
			fixture := newDataDirectoriesFixture(t)
			fixture.input.Completed = completed
			fixture.input.Dirs = []string{"missing"}
			fixture.compare(t, "findings")
			fixture.compare(t, "warnings")
		})
	}
}

func TestDataDirectoryRelativePaths(t *testing.T) {
	for _, path := range []string{".", "./fresh", "directory///", "directory/./fresh", "directory//fresh", "file/.", "file/child", "space and=equals", "-option", "back\\slash"} {
		t.Run(path, func(t *testing.T) {
			fixture := newDataDirectoriesFixture(t)
			if err := os.Mkdir(filepath.Join(fixture.input.Dir, "directory"), 0o700); err != nil {
				t.Fatal(err)
			}
			verificationFile(t, filepath.Join(fixture.input.Dir, "file"))
			fixture.input.Dirs = []string{path}
			fixture.compare(t, "missing")
			fixture.compare(t, "findings")
		})
	}
}

func TestDataDirectoryEmptyAndExtraEntries(t *testing.T) {
	for _, dirs := range [][]string{nil, {"", "", "", "", ""}, {"", "missing"}, {"", "", "", "", "", "ignored"}} {
		t.Run(strings.Join(dirs, ","), func(t *testing.T) {
			fixture := newDataDirectoriesFixture(t)
			fixture.input.Dirs = dirs
			for _, operation := range []string{"missing", "findings", "warnings"} {
				fixture.compare(t, operation)
			}
		})
	}
}

func TestDataDirectoryTrailingNewlines(t *testing.T) {
	fixture := newDataDirectoriesFixture(t)
	fixture.input.Completed = "true\n\n"
	fixture.input.Dirs = []string{fixture.input.Dir + "\n", "fresh\n\n", "\n", "", "space=and'quote\n"}
	for _, operation := range []string{"missing", "findings", "warnings"} {
		fixture.compare(t, operation)
	}
}

func TestDataDirectoryEscapedWarnings(t *testing.T) {
	fixture := newDataDirectoriesFixture(t)
	fixture.input.Dirs = []string{`missing\nfolder`}
	fixture.compare(t, "missing")
	fixture.compare(t, "findings")
	result := fixture.reference(t, "warnings")
	warnings, err := fixture.input.Warnings()
	if result.code != 0 || !strings.Contains(result.stderr, "missing\nfolder (not found)") || warnings != nil || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("Bash %+v, Go warnings %+v, %v", result, warnings, err)
	}
}

func TestDataDirectoryDeploymentFiles(t *testing.T) {
	for _, state := range []string{"missing", "file", "directory", "file link", "directory link", "dangling", "relative dot", "absolute", "custom name", "empty override"} {
		for _, appliance := range []bool{false, true} {
			t.Run(state+"/"+boolName(appliance), func(t *testing.T) {
				fixture := newDataDirectoriesFixture(t)
				fixture.input.Appliance = appliance
				switch state {
				case "relative dot":
					fixture.envFile = "./.env"
				case "absolute":
					fixture.envFile = filepath.Join(fixture.input.Dir, ".env")
				case "custom name":
					fixture.envFile = "custom env='file"
				case "empty override":
					fixture.envFile = ""
				}
				path := fixture.envFile
				if path == "" {
					path = ".env"
				}
				if !filepath.IsAbs(path) {
					path = fixture.input.Dir + string(os.PathSeparator) + path
				}
				switch state {
				case "directory":
					if err := os.Mkdir(path, 0o700); err != nil {
						t.Fatal(err)
					}
				case "file link", "directory link", "dangling":
					if state == "file link" {
						verificationFile(t, path+".target")
					} else if state == "directory link" {
						if err := os.Mkdir(path+".target", 0o700); err != nil {
							t.Fatal(err)
						}
					}
					if err := os.Symlink(path+".target", path); err != nil {
						t.Fatal(err)
					}
				case "missing":
				default:
					verificationFile(t, path)
				}
				fixture.compare(t, "deployment")
			})
		}
	}
}

func TestDataDirectoryDeploymentCompleted(t *testing.T) {
	for _, completed := range []string{"", "false", "TRUE", "yes", "1", "true ", "true\r", "true\n\n", "true"} {
		for _, appliance := range []bool{false, true} {
			t.Run(strconv.Quote(completed)+"/"+boolName(appliance), func(t *testing.T) {
				fixture := newDataDirectoriesFixture(t)
				fixture.input.Completed, fixture.input.Appliance = completed, appliance
				verificationFile(t, filepath.Join(fixture.input.Dir, fixture.envFile))
				fixture.compare(t, "deployment")
			})
		}
	}
}
