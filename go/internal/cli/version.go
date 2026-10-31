package cli

import (
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
)

func writeVersion(w io.Writer, dir string) error {
	version := installedVersion(dir)
	if info, err := os.Stat(filepath.Join(dir, "dashboard", "Dockerfile")); err == nil && info.Mode().IsRegular() {
		commit, branch := "", ""
		if _, err := gitOutput(dir, "rev-parse", "--git-dir"); err == nil {
			commit, _ = gitOutput(dir, "rev-parse", "--short", "HEAD")
			branch, _ = gitOutput(dir, "rev-parse", "--abbrev-ref", "HEAD")
			if commit != "" {
				if _, err := gitOutput(dir, "diff", "--quiet", "HEAD"); err != nil {
					commit += "-dirty"
				}
			}
		}
		_, err := fmt.Fprintf(w, "pithead dev (%s @ %s, VERSION %s)\n", orUnknown(branch), orUnknown(commit), orUnknown(version))
		return err
	}
	installed, images := "unknown", "dev"
	if version != "" {
		installed, images = "v"+version, "v"+version
	}
	_, err := fmt.Fprintf(w, "pithead %s (release images %s)\n", installed, images)
	return err
}

func gitOutput(dir string, args ...string) (string, error) {
	cmd := exec.Command("git", args...)
	cmd.Dir = dir
	output, err := cmd.Output()
	return strings.TrimRight(strings.ReplaceAll(string(output), "\x00", ""), "\n"), err
}

func installedVersion(dir string) string {
	if info, err := os.Stat(filepath.Join(dir, "VERSION")); err == nil && info.Mode().IsRegular() {
		if data, err := os.ReadFile(filepath.Join(dir, "VERSION")); err == nil {
			return strings.NewReplacer(" ", "", "\t", "", "\r", "", "\n", "", "\x00", "").Replace(string(data))
		}
	}
	return ""
}

func orUnknown(value string) string {
	if value == "" {
		return "unknown"
	}
	return value
}
