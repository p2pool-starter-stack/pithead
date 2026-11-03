package status

import (
	"os"
	"regexp"
	"strings"
)

var (
	migrationMarkerPattern  = regexp.MustCompile(`^[0-9.vAB|]+$`)
	migrationVersionPattern = regexp.MustCompile(`^v?[0-9]+\.[0-9]+\.[0-9]+$`)
)

func (r *Runner) migrationHold() bool {
	marker := os.Getenv("PITHEAD_MIGRATION_MARKER_FILE")
	if marker == "" {
		marker = "/data/pithead/.os-migration-pending"
	}
	content, err := os.ReadFile(r.path(marker))
	if err != nil {
		return false
	}
	value := deleteShellWhitespace(string(content))
	if !migrationMarkerPattern.MatchString(value) {
		return false
	}
	version, slot, qualified := strings.Cut(value, "|")
	if !migrationVersionPattern.MatchString(version) {
		return false
	}
	if qualified && slot != "A" && slot != "B" {
		return false
	}
	running, err := os.ReadFile(r.path("VERSION"))
	if err != nil {
		return false
	}
	current := deleteShellWhitespace(string(running))
	if !qualified {
		return value == current
	}
	booted := r.bootedSlot()
	return (booted == "A" || booted == "B") && slot == booted && value == current+"|"+booted
}

func (r *Runner) bootedSlot() string {
	cmdline := os.Getenv("PITHEAD_CMDLINE")
	if cmdline == "" {
		cmdline = "/proc/cmdline"
	}
	content, err := os.ReadFile(r.path(cmdline))
	if err != nil {
		return ""
	}
	var slots []string
	for _, token := range strings.Split(strings.ReplaceAll(string(content), " ", "\n"), "\n") {
		if token == "rauc.slot=A" || token == "rauc.slot=B" {
			slots = append(slots, strings.TrimPrefix(token, "rauc.slot="))
		}
	}
	return strings.Join(slots, "\n")
}

func deleteShellWhitespace(value string) string {
	return strings.Map(func(char rune) rune {
		if char == ' ' || char == '\t' || char == '\r' || char == '\n' {
			return -1
		}
		return char
	}, value)
}
