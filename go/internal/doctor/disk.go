package doctor

import (
	"bytes"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

var diskComponents = [...]string{"monero", "tari", "p2pool", "dashboard", "tor"}
var errDiskDFUnavailable = errors.New("disk df unavailable")

type Disk struct {
	Dir  string
	Dirs []string
}

type diskGroup struct {
	mount       string
	requiredGiB int64
	components  []string
}

func DiskComponentGiB(component string) int64 {
	switch component {
	case "monero":
		return 320
	case "tari":
		return 200
	case "p2pool":
		return 5
	case "dashboard":
		return 2
	case "tor":
		return 1
	default:
		return 0
	}
}

func (disk Disk) Mount(path string) (string, error) {
	dir, err := disk.validated([]string{path})
	if err != nil {
		return "", err
	}
	return disk.mount(dir, path)
}

func (disk Disk) Check(mode string) ([]Finding, error) {
	paths := disk.Dirs
	if len(paths) > len(diskComponents) {
		paths = paths[:len(diskComponents)]
	}
	dir, err := disk.validated(paths)
	if err != nil {
		return nil, err
	}
	groups := make([]diskGroup, 0, len(diskComponents))
	for index, component := range diskComponents {
		if index >= len(disk.Dirs) || disk.Dirs[index] == "" {
			continue
		}
		mount, mountErr := disk.mount(dir, disk.Dirs[index])
		if mountErr != nil {
			return nil, mountErr
		}
		if mount == "" {
			continue
		}
		groupIndex := -1
		for index := range groups {
			if groups[index].mount == mount {
				groupIndex = index
				break
			}
		}
		if groupIndex < 0 {
			groups = append(groups, diskGroup{mount: mount, requiredGiB: DiskComponentGiB(component), components: []string{component}})
			continue
		}
		groups[groupIndex].requiredGiB += DiskComponentGiB(component)
		groups[groupIndex].components = append(groups[groupIndex].components, component)
	}
	if len(groups) == 0 {
		if mode == "doctor" {
			return []Finding{{"disk-space", "info", "No data dirs resolved to a filesystem — skipping disk check."}}, nil
		}
		return nil, nil
	}

	findings := make([]Finding, 0, len(groups))
	for _, group := range groups {
		available, err := disk.dfField(dir, "-P", group.mount, 4)
		if err != nil {
			return nil, err
		}
		human, err := disk.dfField(dir, "-Ph", group.mount, 4)
		if err != nil {
			return nil, err
		}
		if mode != "doctor" && strings.Contains(human, "\\") {
			return nil, ErrUnsupportedProbeInput
		}
		availableKiB, numeric := diskInteger(available)
		components := strings.Join(group.components, ", ")
		if mode == "doctor" {
			if numeric && availableKiB >= group.requiredGiB*1048576 {
				findings = append(findings, Finding{"disk-space", "ok", fmt.Sprintf("Data on %s (%s): %s free — needs ~%d GiB.", group.mount, components, displayDiskFree(human), group.requiredGiB)})
			} else {
				findings = append(findings, Finding{"disk-space", "warn", fmt.Sprintf("Data on %s (%s): %s free — below the ~%d GiB the stack needs there.", group.mount, components, displayDiskFree(human), group.requiredGiB)})
			}
			continue
		}
		if numeric && availableKiB < group.requiredGiB*1048576 {
			findings = append(findings, Finding{"", "warn", fmt.Sprintf("Low disk on %s (hosts %s): %s free, below the ~%d GiB the stack needs there — free space or move a data_dir to a larger volume.", group.mount, components, displayDiskFree(human), group.requiredGiB)})
		}
	}
	if len(findings) == 0 {
		return nil, nil
	}
	return findings, nil
}

func (disk Disk) validated(paths []string) (string, error) {
	dir := disk.Dir
	if dir == "" {
		var err error
		dir, err = os.Getwd()
		if err != nil {
			return "", ErrUnsupportedProbeInput
		}
	}
	if invalidDiskPath(dir) || !filepath.IsAbs(dir) {
		return "", ErrUnsupportedProbeInput
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return "", ErrUnsupportedProbeInput
	}
	pathValue := os.Getenv("PATH")
	if pathValue == "" {
		return "", ErrUnsupportedProbeInput
	}
	for _, entry := range filepath.SplitList(pathValue) {
		if entry == "" || !filepath.IsAbs(entry) {
			return "", ErrUnsupportedProbeInput
		}
	}
	for _, path := range paths {
		if path != "" && invalidDiskPath(path) {
			return "", ErrUnsupportedProbeInput
		}
	}
	if hasDiskPath(paths) {
		if _, err := exec.LookPath("awk"); err != nil {
			return "", ErrUnsupportedProbeInput
		}
	}
	return dir, nil
}

func (disk Disk) mount(dir, path string) (string, error) {
	if path == "" {
		return "", nil
	}
	ancestor := path
	for {
		statPath := ancestor
		if !filepath.IsAbs(statPath) {
			statPath = dir + string(filepath.Separator) + statPath
		}
		if _, err := os.Stat(statPath); err == nil {
			break
		}
		parent, err := runDiskDirname(dir, ancestor)
		if err != nil || parent == ancestor {
			return "", ErrUnsupportedProbeInput
		}
		if parent == "" {
			return "", nil
		}
		ancestor = parent
	}
	mount, err := disk.dfFieldAllowFailure(dir, "-P", ancestor, 6)
	if err != nil {
		return "", err
	}
	if mount != "" && (invalidDiskPath(mount) || strings.Contains(mount, "\\") || !filepath.IsAbs(mount)) {
		return "", ErrUnsupportedProbeInput
	}
	return mount, nil
}

func (disk Disk) dfField(dir, option, path string, field int) (string, error) {
	value, err := runDiskDF(dir, option, path, field)
	if err != nil {
		return "", ErrUnsupportedProbeInput
	}
	return value, nil
}

func (disk Disk) dfFieldAllowFailure(dir, option, path string, field int) (string, error) {
	value, err := runDiskDF(dir, option, path, field)
	if err == nil {
		return value, nil
	}
	if errors.Is(err, errDiskDFUnavailable) {
		return "", nil
	}
	return "", ErrUnsupportedProbeInput
}

func runDiskDF(dir, option, path string, field int) (string, error) {
	var output bytes.Buffer
	command := exec.Command("df", option, path)
	command.Dir = dir
	command.Stdout = &output
	if err := command.Run(); err != nil {
		var exit *exec.ExitError
		var missing *exec.Error
		if errors.As(err, &exit) || errors.As(err, &missing) {
			return "", errDiskDFUnavailable
		}
		return "", ErrUnsupportedProbeInput
	}
	if bytes.IndexByte(output.Bytes(), 0) >= 0 {
		return "", ErrUnsupportedProbeInput
	}
	var selected, diagnostics bytes.Buffer
	awk := exec.Command("awk", fmt.Sprintf("NR==2{print $%d}", field))
	awk.Dir = dir
	awk.Stdin = bytes.NewReader(output.Bytes())
	awk.Stdout = &selected
	awk.Stderr = &diagnostics
	if err := awk.Run(); err != nil || diagnostics.Len() != 0 {
		return "", ErrUnsupportedProbeInput
	}
	return diskCommandOutput(selected.String())
}

func runDiskDirname(dir, path string) (string, error) {
	var output, diagnostics bytes.Buffer
	command := exec.Command("dirname", path)
	command.Dir = dir
	command.Stdout = &output
	command.Stderr = &diagnostics
	if err := command.Run(); err != nil || diagnostics.Len() != 0 {
		return "", ErrUnsupportedProbeInput
	}
	parent, err := diskCommandOutput(output.String())
	if err != nil || invalidDiskPath(parent) {
		return "", ErrUnsupportedProbeInput
	}
	return parent, nil
}

func diskCommandOutput(output string) (string, error) {
	value := strings.TrimRight(output, "\n")
	if strings.ContainsRune(value, 0) || strings.ContainsRune(value, '\n') {
		return "", ErrUnsupportedProbeInput
	}
	return value, nil
}

func diskInteger(value string) (int64, bool) {
	number, err := strconv.ParseInt(strings.Trim(value, " \t\n\v\f\r"), 10, 64)
	return number, err == nil
}

func hasDiskPath(paths []string) bool {
	for _, path := range paths {
		if path != "" {
			return true
		}
	}
	return false
}

func invalidDiskPath(path string) bool {
	return strings.ContainsRune(path, 0) || strings.ContainsRune(path, '\n') || parentPathComponent(path)
}

func displayDiskFree(value string) string {
	if value == "" {
		return "?"
	}
	return value
}
