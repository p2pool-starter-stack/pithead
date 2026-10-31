package status

import (
	"os"
	"path/filepath"
	"testing"
)

func TestMigrationHold(t *testing.T) {
	tests := []struct {
		name    string
		marker  *string
		version string
		cmdline string
		want    bool
	}{
		{"matching version", stringPointer("1.17.0\n"), "1.17.0\n", "", true},
		{"version whitespace", stringPointer(" 1.17.0\t\n"), "1. 17.0\r\n", "", true},
		{"inherited version ignored", stringPointer("1.17.0"), "1.17.0", "", true},
		{"other version", stringPointer("1.17.0"), "1.16.0", "", false},
		{"absent", nil, "1.17.0", "", false},
		{"empty", stringPointer(""), "1.17.0", "", false},
		{"invalid version", stringPointer("1.17.0-prep"), "1.17.0-prep", "", false},
		{"matching slot", stringPointer("v1.17.0|A"), "v1.17.0", "quiet rauc.slot=A console=ttyS0\n", true},
		{"other slot", stringPointer("1.17.0|A"), "1.17.0", "rauc.slot=B\n", false},
		{"missing slot", stringPointer("1.17.0|A"), "1.17.0", "quiet\n", false},
		{"multiple slots", stringPointer("1.17.0|A"), "1.17.0", "rauc.slot=A rauc.slot=B\n", false},
		{"invalid marker slot", stringPointer("1.17.0|C"), "1.17.0", "rauc.slot=C\n", false},
		{"extra separator", stringPointer("1.17.0|A|B"), "1.17.0", "rauc.slot=A\n", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			dir := t.TempDir()
			if err := os.WriteFile(filepath.Join(dir, "VERSION"), []byte(test.version), 0o600); err != nil {
				t.Fatal(err)
			}
			marker := filepath.Join(dir, "marker")
			if test.marker != nil {
				if err := os.WriteFile(marker, []byte(*test.marker), 0o600); err != nil {
					t.Fatal(err)
				}
			}
			cmdline := filepath.Join(dir, "cmdline")
			if err := os.WriteFile(cmdline, []byte(test.cmdline), 0o600); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PITHEAD_MIGRATION_MARKER_FILE", marker)
			t.Setenv("PITHEAD_CMDLINE", cmdline)
			t.Setenv("PITHEAD_VERSION", "wrong-inherited-version")
			if got := (&Runner{Dir: dir}).migrationHold(); got != test.want {
				t.Fatalf("got %t, want %t", got, test.want)
			}
		})
	}
}

func TestMigrationHoldRelativeOverrides(t *testing.T) {
	dir := t.TempDir()
	for name, content := range map[string]string{
		"VERSION": "2.0.0\n",
		"marker":  "2.0.0|B\n",
		"cmdline": "rauc.slot=B\n",
	} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte(content), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("PITHEAD_MIGRATION_MARKER_FILE", "marker")
	t.Setenv("PITHEAD_CMDLINE", "cmdline")
	if !(&Runner{Dir: dir}).migrationHold() {
		t.Fatal("relative marker and cmdline overrides did not resolve from Runner.Dir")
	}
}

func stringPointer(value string) *string {
	return &value
}
