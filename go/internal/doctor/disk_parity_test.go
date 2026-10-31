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

func TestDiskComponentBudgets(t *testing.T) {
	fixture := newDiskFixture(t)
	for _, component := range []string{"monero", "tari", "p2pool", "dashboard", "tor", "unknown", ""} {
		for _, prune := range []string{"0", "1", "ignored"} {
			result := fixture.reference(t, "component", component, prune)
			got := strconv.FormatInt(DiskComponentGiB(component), 10) + "\n"
			if result.code != 0 || result.stderr != "" || result.stdout != got {
				t.Fatalf("%s/%s: Bash %+v, Go %q", component, prune, result, got)
			}
		}
	}
}

func TestDiskGroupedThresholds(t *testing.T) {
	for _, mode := range []string{"doctor", "preflight", "other"} {
		for _, available := range []string{"553648127", "553648128", "553648129", "000553648128", "+553648128", "553648128\r", "\v553648128", "-1", "not-a-number", "9223372036854775808", ""} {
			t.Run(mode+"/"+available, func(t *testing.T) {
				fixture := newDiskFixture(t)
				fixture.dataDirs(t)
				mount := filepath.Join(fixture.input.Dir, "volume")
				var responses []diskResponse
				for _, dir := range fixture.input.Dirs {
					responses = append(responses, diskCapacity(dir, mount, 600))
				}
				numeric := diskOutput(available, mount)
				if available == "" {
					numeric = "header\n"
				}
				responses = append(responses, diskResponse{path: mount, numeric: numeric, human: diskOutput("600G", mount)})
				fixture.tools(t, responses...)
				fixture.compare(t, mode, "1")
			})
		}
	}
}

func TestDiskMultipleMounts(t *testing.T) {
	for _, remote := range []string{"none", "monero", "tari", "both"} {
		t.Run(remote, func(t *testing.T) {
			fixture := newDiskFixture(t)
			fixture.dataDirs(t)
			big, small := filepath.Join(fixture.input.Dir, "big"), filepath.Join(fixture.input.Dir, "small")
			var responses []diskResponse
			for i, dir := range fixture.input.Dirs {
				mount := small
				if i < 2 {
					mount = big
				}
				responses = append(responses, diskCapacity(dir, mount, 600))
			}
			responses = append(responses, diskCapacity(big, big, 600), diskCapacity(small, small, 7))
			fixture.tools(t, responses...)
			if remote == "monero" || remote == "both" {
				fixture.input.Dirs[0] = ""
			}
			if remote == "tari" || remote == "both" {
				fixture.input.Dirs[1] = ""
			}
			for _, mode := range []string{"doctor", "preflight"} {
				resetVerificationCalls(t, fixture.log)
				fixture.compare(t, mode, "0")
			}
		})
	}
}

func TestDiskMountAncestors(t *testing.T) {
	for _, path := range []string{"directory", "directory/fresh/deep", "./directory/fresh/deep", "directory//fresh/deep", "directory/./fresh", "directory///", "file", "file/child", "file/.", "link/fresh", "dangling", "missing", ".", ""} {
		t.Run(path, func(t *testing.T) {
			fixture := newDiskFixture(t)
			base := fixture.input.Dir
			if err := os.Mkdir(filepath.Join(base, "directory"), 0o700); err != nil {
				t.Fatal(err)
			}
			verificationFile(t, filepath.Join(base, "file"))
			for name, target := range map[string]string{"link": "directory", "dangling": "missing"} {
				if err := os.Symlink(target, filepath.Join(base, name)); err != nil {
					t.Fatal(err)
				}
			}
			ancestor := path
			switch path {
			case "directory/fresh/deep", "directory//fresh/deep":
				ancestor = "directory"
			case "./directory/fresh/deep":
				ancestor = "./directory"
			case "directory/./fresh":
				ancestor = "directory/."
			case "file/child", "file/.":
				ancestor = "file"
			case "link/fresh":
				ancestor = "link"
			case "dangling", "missing":
				ancestor = "."
			}
			fixture.tools(t, diskCapacity(ancestor, "/fixture", 600))
			result := fixture.reference(t, "mount", path)
			calls := verificationCalls(t, fixture.log)
			resetVerificationCalls(t, fixture.log)
			got, err := fixture.input.Mount(path)
			if err != nil || result.stdout != got || result.stderr != "" || (result.code == 0) != (got != "") {
				t.Fatalf("Bash %+v, Go mount %q, %v", result, got, err)
			}
			if got := verificationCalls(t, fixture.log); got != calls {
				t.Fatalf("Go calls %q, Bash calls %q", got, calls)
			}
		})
	}
}

func TestDiskGroupedMissingAndUnresolved(t *testing.T) {
	for _, state := range []string{"fresh", "no dirs", "unresolved", "df failure", "short dirs", "extra dirs"} {
		for _, mode := range []string{"doctor", "preflight"} {
			t.Run(state+"/"+mode, func(t *testing.T) {
				fixture := newDiskFixture(t)
				mount := filepath.Join(fixture.input.Dir, "volume")
				for _, component := range []string{"monero", "tari", "p2pool", "dashboard", "tor"} {
					fixture.input.Dirs = append(fixture.input.Dirs, filepath.Join(fixture.input.Dir, "fresh", component))
				}
				responses := []diskResponse{diskCapacity(fixture.input.Dir, mount, 600), diskCapacity(mount, mount, 600)}
				switch state {
				case "no dirs":
					fixture.input.Dirs = nil
				case "unresolved":
					responses[0].numeric = "header\n"
				case "df failure":
					responses[0].numericExit = 7
				case "short dirs":
					fixture.input.Dirs = fixture.input.Dirs[:2]
				case "extra dirs":
					fixture.input.Dirs = append(fixture.input.Dirs, "/ignored")
				}
				fixture.tools(t, responses...)
				fixture.compare(t, mode, "1")
			})
		}
	}
}

func TestDiskDFFields(t *testing.T) {
	for _, response := range []string{"header\nfixture\t9\t9\t600G\t1%\t/fixture\n", "header\nfixture 9 9 600G 1% /fixture with spaces\n", "header\nfixture 9 9 600\u00a0G 1% /fixture\n", "header\nfixture 9 9 600\fG 1% /fixture\n", "header\nfixture 9 9 600G\r 1% /fixture\n", "header\nfixture 9 9 600\\nG 1% /fixture\n", "header\n", "", "header\nfixture 9 9 1G 1% /fixture\nfixture 9 9 999G 1% /ignored\n"} {
		t.Run(strconv.Quote(response), func(t *testing.T) {
			fixture := newDiskFixture(t)
			fixture.input.Dirs = []string{fixture.input.Dir}
			fixture.tools(t, diskCapacity(fixture.input.Dir, "/fixture", 600), diskResponse{path: "/fixture", numeric: diskOutput("629145600", "/fixture"), human: response})
			fixture.compare(t, "doctor", "1")
		})
	}
}

func TestDiskCapacityFailure(t *testing.T) {
	for _, failure := range []string{"numeric", "human", "no shebang"} {
		t.Run(failure, func(t *testing.T) {
			fixture := newDiskFixture(t)
			fixture.input.Dirs = []string{fixture.input.Dir}
			responses := []diskResponse{diskCapacity(fixture.input.Dir, "/fixture", 600), diskCapacity("/fixture", "/fixture", 600)}
			if failure == "numeric" {
				responses[1].numericExit = 9
			} else if failure == "human" {
				responses[1].humanExit = 9
			}
			fixture.tools(t, responses...)
			if failure == "no shebang" {
				file := filepath.Join(fixture.bin, "df")
				body, err := os.ReadFile(file)
				if err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(file, []byte(strings.TrimPrefix(string(body), "#!/bin/sh\n")), 0o700); err != nil {
					t.Fatal(err)
				}
			}
			result := fixture.reference(t, "grouped", "doctor", "1", fixture.input.Dir)
			findings, err := fixture.input.Check("doctor")
			if !errors.Is(err, ErrUnsupportedProbeInput) || len(findings) != 0 || (failure != "no shebang" && result.code == 0) {
				t.Fatalf("Bash %+v, Go %+v, %v", result, findings, err)
			}
		})
	}
}

func TestDiskNULFallback(t *testing.T) {
	for _, field := range []string{"mount", "numeric", "human"} {
		t.Run(field, func(t *testing.T) {
			fixture := newDiskFixture(t)
			fixture.input.Dirs = []string{fixture.input.Dir}
			responses := []diskResponse{diskCapacity(fixture.input.Dir, "/fixture", 600), diskCapacity("/fixture", "/fixture", 600)}
			switch field {
			case "mount":
				responses[0].numeric = diskOutput("629145600", "/fix\x00ture")
			case "numeric":
				responses[1].numeric = diskOutput("6291\x0045600", "/fixture")
			case "human":
				responses[1].human = diskOutput("600\x00G", "/fixture")
			}
			fixture.tools(t, responses...)
			result := fixture.reference(t, "grouped", "doctor", "1", fixture.input.Dir)
			findings, err := fixture.input.Check("doctor")
			if !errors.Is(err, ErrUnsupportedProbeInput) || len(findings) != 0 {
				t.Fatalf("Bash %+v, Go %+v, %v", result, findings, err)
			}
		})
	}
}
