package doctor

import (
	"errors"
	"path/filepath"
	"testing"
)

func TestControlUnitsMultilinePaths(t *testing.T) {
	root := t.TempDir()
	installSystemctl(t, root)
	base := ControlUnits{InstallDir: root, UnitDir: filepath.Join(root, "units"), ControlDir: filepath.Join(root, "spool"), Enabled: "true", OS: "Linux"}
	for _, field := range []string{"install", "unit", "spool", "unit-parent", "install-parent"} {
		input := base
		switch field {
		case "install":
			input.InstallDir += "\nline"
		case "unit":
			input.UnitDir += "\nline"
		case "spool":
			input.ControlDir += "\nline"
		case "unit-parent":
			input.UnitDir += "/../units"
		case "install-parent":
			input.InstallDir += "/../install"
		}
		finding, section, err := input.Finding()
		if finding != (Finding{}) || !section || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("%s = %+v, %v, %v", field, finding, section, err)
		}
	}
}
