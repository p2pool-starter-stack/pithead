package doctor

import (
	"os"
	"path/filepath"
	"strings"
)

var dataDirectoryNames = [...]string{
	"MONERO_DATA_DIR",
	"TARI_DATA_DIR",
	"P2POOL_DATA_DIR",
	"DASHBOARD_DATA_DIR",
	"TOR_DATA_DIR",
}

type DataDirectories struct {
	Dir       string
	Completed string
	Dirs      []string
	Appliance bool
}

func (data DataDirectories) Missing() ([]string, error) {
	completed, err := probeValue(data.Completed)
	if err != nil {
		return nil, err
	}
	if completed != "true" {
		return nil, nil
	}
	dir, err := probeDirectory(data.Dir)
	if err != nil {
		return nil, err
	}
	missing := make([]string, 0, len(dataDirectoryNames))
	for index, name := range dataDirectoryNames {
		if index >= len(data.Dirs) {
			break
		}
		path, valueErr := probeValue(data.Dirs[index])
		if valueErr != nil || invalidProbePath(path) {
			return nil, ErrUnsupportedProbeInput
		}
		if path == "" {
			continue
		}
		statPath := path
		if !filepath.IsAbs(statPath) {
			statPath = dir + string(os.PathSeparator) + statPath
		}
		info, statErr := os.Stat(statPath)
		if statErr != nil || !info.IsDir() {
			missing = append(missing, name+"="+path)
		}
	}
	if len(missing) == 0 {
		return nil, nil
	}
	return missing, nil
}

func (data DataDirectories) Findings() ([]Finding, error) {
	missing, err := data.Missing()
	if err != nil {
		return nil, err
	}
	completed, err := probeValue(data.Completed)
	if err != nil {
		return nil, err
	}
	if completed != "true" {
		return nil, nil
	}
	if len(missing) == 0 {
		return []Finding{{"data-directories", "ok", "Data directories named in .env are present."}}, nil
	}
	findings := make([]Finding, 0, len(missing))
	for _, line := range missing {
		name, path, _ := strings.Cut(line, "=")
		message := "Data dir from .env not found: " + name + "=" + path + " — a relocated/copied install re-syncs from scratch. Move the data here, or set the data_dir in config.json and run 'apply'."
		if data.Appliance {
			message = "Data dir from .env not found: " + name + "=" + path + " — this machine re-syncs that data from scratch, and the dashboard history recorded against it is orphaned. With the dashboard control channel on, all five data dirs can be repointed from Configuration behind its confirmation step. Moving existing data back is not a dashboard action and needs console access to this machine."
		}
		findings = append(findings, Finding{"data-directories", "warn", message})
	}
	return findings, nil
}

func (data DataDirectories) Warnings() ([]string, error) {
	missing, err := data.Missing()
	if err != nil {
		return nil, err
	}
	if len(missing) == 0 {
		return nil, nil
	}
	for _, line := range missing {
		if strings.Contains(line, `\`) {
			return nil, ErrUnsupportedProbeInput
		}
	}
	warnings := []string{"Data directories named in .env are MISSING — did you relocate, copy, or run a different checkout of this install?"}
	for _, line := range missing {
		name, path, _ := strings.Cut(line, "=")
		warnings = append(warnings, "  "+name+" → "+path+" (not found)")
	}
	warnings = append(warnings,
		"The stack will start a FRESH sync and the dashboard history will be orphaned. To keep your synced chains,",
		"move the data to these paths, or set the data_dir(s) in config.json (absolute) and run './pithead apply'.",
	)
	return warnings, nil
}

func probeDirectory(dir string) (string, error) {
	if dir == "" {
		var err error
		dir, err = os.Getwd()
		if err != nil {
			return "", ErrUnsupportedProbeInput
		}
	}
	if !filepath.IsAbs(dir) || invalidProbePath(dir) {
		return "", ErrUnsupportedProbeInput
	}
	info, err := os.Stat(dir)
	if err != nil || !info.IsDir() {
		return "", ErrUnsupportedProbeInput
	}
	return dir, nil
}

func probeValue(value string) (string, error) {
	value = strings.TrimRight(value, "\n")
	if strings.ContainsRune(value, 0) {
		return "", ErrUnsupportedProbeInput
	}
	return value, nil
}

func invalidProbePath(path string) bool {
	if strings.ContainsAny(path, "\x00\r\n") {
		return true
	}
	for _, part := range strings.Split(path, string(os.PathSeparator)) {
		if part == ".." {
			return true
		}
	}
	return false
}
