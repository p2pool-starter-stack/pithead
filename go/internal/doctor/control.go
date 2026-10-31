package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strings"
)

var versionedInstall = regexp.MustCompile(`^pithead-v[0-9]+\.[0-9]+\.[0-9]+$`)

type ControlUnits struct {
	InstallDir string
	ControlDir string
	UnitDir    string
	Enabled    string
	OS         string
	Appliance  bool
}

func ControlUnitDir(override string, appliance bool) string {
	if override != "" {
		return override
	}
	if appliance {
		return "/run/systemd/system"
	}
	return "/etc/systemd/system"
}

func ControlUnitsOwnerDir(unitDir, service, verb string) (string, error) {
	if strings.ContainsRune(unitDir, 0) || strings.ContainsRune(service, 0) || strings.ContainsRune(verb, 0) {
		return "", ErrUnsupportedProbeInput
	}
	if service == "" {
		service = "pithead-control.service"
	}
	if verb == "" {
		verb = "control-run-pending"
	}
	if !literalControlVerb(verb) {
		return "", ErrUnsupportedProbeInput
	}
	content, err := os.ReadFile(filepath.Join(unitDir, service))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) || errors.Is(err, os.ErrPermission) {
			return "", nil
		}
		return "", ErrUnsupportedProbeInput
	}
	if bytes.IndexByte(content, 0) >= 0 {
		return "", ErrUnsupportedProbeInput
	}
	suffix := "/pithead " + verb
	for _, line := range strings.Split(string(content), "\n") {
		if !strings.HasPrefix(line, "ExecStart=/") || !strings.HasSuffix(line, suffix) {
			continue
		}
		owner := strings.TrimSuffix(strings.TrimPrefix(line, "ExecStart="), suffix)
		if owner == "" {
			return "", nil
		}
		return physicalPreservingMissing(owner)
	}
	return "", nil
}

func (control ControlUnits) Finding() (Finding, bool, error) {
	if control.OS != "Linux" {
		return Finding{}, false, nil
	}
	pathValue := os.Getenv("PATH")
	if pathValue == "" {
		return Finding{}, false, ErrUnsupportedProbeInput
	}
	for _, path := range filepath.SplitList(pathValue) {
		if path == "" || !filepath.IsAbs(path) {
			return Finding{}, false, ErrUnsupportedProbeInput
		}
	}
	if _, err := exec.LookPath("systemctl"); err != nil {
		if errors.Is(err, exec.ErrDot) {
			return Finding{}, false, ErrUnsupportedProbeInput
		}
		return Finding{}, false, nil
	}
	if control.invalid() {
		return Finding{}, true, ErrUnsupportedProbeInput
	}
	if !normalizedBool(control.Enabled) {
		return Finding{"control-units", "info", "Disabled for this install — the dashboard cannot apply config changes or upgrade."}, true, nil
	}
	unitDir := ControlUnitDir(control.UnitDir, control.Appliance)
	if parentPathComponent(unitDir) || parentPathComponent(control.InstallDir) {
		return Finding{}, true, ErrUnsupportedProbeInput
	}
	if !filepath.IsAbs(unitDir) {
		unitDir = filepath.Join(control.InstallDir, unitDir)
	}
	owner, err := ControlUnitsOwnerDir(unitDir, "", "")
	if err != nil {
		return Finding{}, true, err
	}
	here, err := physicalInstall(control.InstallDir)
	if err != nil {
		return Finding{}, true, err
	}
	if live := supersededInstall(here); live != "" {
		message := "This is not the live install — '" + filepath.Dir(here) + "/current' points at " + live + ". Run doctor there to check its control channel."
		return Finding{"control-units", "info", message}, true, nil
	}
	if owner == "" {
		message := "The control channel is enabled but no runner units are installed — the dashboard's config changes and one-click upgrades will never run, with no error shown. Fix: run './pithead apply' from this directory."
		if control.Appliance {
			message = "The control channel is enabled but no runner units are installed — config changes and one-click upgrades made here will never run, with no error shown. The installed system provides these units, so this system copy is faulty."
		}
		return Finding{"control-units", "fail", message}, true, nil
	}
	if owner != here {
		message := "The control runner units point at " + owner + ", but this install is " + here + " — the dashboard writes its requests here and nothing reads them, so config changes and one-click upgrades silently never run. Fix: run './pithead apply' from this directory."
		if control.Appliance {
			message = "The control runner units point at " + owner + ", but this install is " + here + " — requests are written here and nothing reads them, so config changes and one-click upgrades silently never run. The installed system sets this up, so this system copy is faulty."
		}
		return Finding{"control-units", "fail", message}, true, nil
	}
	watches, err := pathUnitWatches(unitDir, control.ControlDir)
	if err != nil {
		return Finding{}, true, err
	}
	if control.ControlDir != "" && !watches {
		message := "The control runner watches a different spool than this install writes to (" + control.ControlDir + ") — requests are never picked up, with no error shown. Fix: run './pithead apply' from this directory."
		if control.Appliance {
			message = "The control runner watches a different spool than this install writes to (" + control.ControlDir + ") — requests are never picked up, with no error shown. The installed system sets this up, so this system copy is faulty."
		}
		return Finding{"control-units", "fail", message}, true, nil
	}
	return Finding{"control-units", "ok", "Control runner units target this install."}, true, nil
}

func (control ControlUnits) invalid() bool {
	for _, path := range []string{control.InstallDir, control.ControlDir, control.UnitDir} {
		if strings.ContainsRune(path, '\n') {
			return true
		}
	}
	for _, value := range []string{control.InstallDir, control.ControlDir, control.UnitDir, control.Enabled, control.OS} {
		if strings.ContainsRune(value, 0) {
			return true
		}
	}
	return false
}

func normalizedBool(value string) bool {
	switch strings.ToLower(strings.TrimRight(value, "\n")) {
	case "true", "1", "yes", "on":
		return true
	default:
		return false
	}
}

func pathUnitWatches(unitDir, controlDir string) (bool, error) {
	if controlDir == "" {
		return false, nil
	}
	content, err := os.ReadFile(filepath.Join(unitDir, "pithead-control.path"))
	if err != nil {
		return false, nil
	}
	if bytes.IndexByte(content, 0) >= 0 {
		return false, ErrUnsupportedProbeInput
	}
	return bytes.Contains(content, []byte("PathExistsGlob="+controlDir+"/requests/*.json")), nil
}

func physicalInstall(path string) (string, error) {
	if parentPathComponent(path) {
		return "", ErrUnsupportedProbeInput
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	physical, err := filepath.EvalSymlinks(abs)
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	info, err := os.Stat(physical)
	if err != nil || !info.IsDir() {
		return "", ErrUnsupportedProbeInput
	}
	return physical, nil
}

func physicalPreservingMissing(path string) (string, error) {
	if parentPathComponent(path) {
		return "", ErrUnsupportedProbeInput
	}
	abs, err := filepath.Abs(path)
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	dir, tail := filepath.Clean(abs), ""
	for dir != filepath.Dir(dir) {
		info, statErr := os.Stat(dir)
		if statErr == nil && info.IsDir() {
			break
		}
		tail = filepath.Join(filepath.Base(dir), tail)
		dir = filepath.Dir(dir)
	}
	physical, err := filepath.EvalSymlinks(dir)
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	if tail != "" {
		physical = filepath.Join(physical, tail)
	}
	return physical, nil
}

func parentPathComponent(path string) bool {
	for _, component := range strings.Split(path, string(filepath.Separator)) {
		if component == ".." {
			return true
		}
	}
	return false
}

func literalControlVerb(verb string) bool {
	if verb == "" {
		return false
	}
	for _, char := range verb {
		if (char < 'a' || char > 'z') && (char < 'A' || char > 'Z') && (char < '0' || char > '9') && char != '-' && char != '_' {
			return false
		}
	}
	return true
}

func supersededInstall(here string) string {
	if !versionedInstall.MatchString(filepath.Base(here)) {
		return ""
	}
	current := filepath.Join(filepath.Dir(here), "current")
	info, err := os.Lstat(current)
	if err != nil || info.Mode()&os.ModeSymlink == 0 {
		return ""
	}
	live, err := physicalInstall(current)
	if err != nil || live == here {
		return ""
	}
	return live
}
