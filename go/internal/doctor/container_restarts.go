package doctor

import (
	"bytes"
	"errors"
	"os/exec"
	"regexp"
	"strconv"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

const restartInspectFormat = "{{.Id}}\t{{.Name}}\t{{.State.Status}}\t{{.RestartCount}}\t{{.State.StartedAt}}"

var (
	restartIDPattern      = regexp.MustCompile(`^[0-9a-f]+$`)
	restartCountPattern   = regexp.MustCompile(`^[0-9]+$`)
	restartComposePattern = regexp.MustCompile(`^[0-9a-f]{12}_(.+)$`)
)

type restartRow struct {
	id      string
	name    string
	state   string
	count   string
	started string
}

var errRestartObservation = errors.New("container restart observation failed")

func ContainerRestarts(dir string) ([]Finding, error) {
	names, err := RestartingContainerNames(dir)
	if errors.Is(err, ErrUnsupportedProbeInput) {
		return nil, err
	}
	if err != nil {
		return []Finding{{"container-restarts", "fail", "Container restart observation failed — the engine state could not be read twice."}}, nil
	}
	findings := make([]Finding, 0, len(names))
	for _, name := range names {
		if name == "" {
			continue
		}
		findings = append(findings, Finding{"container-restarts", "fail", name + " is restarting or restarted during the health check — it may be crash-looping."})
	}
	if len(findings) == 0 {
		return []Finding{{"container-restarts", "ok", "No containers were observed restarting during the health check."}}, nil
	}
	return findings, nil
}

func RestartingContainerNames(dir string) ([]string, error) {
	before, err := containerRestartSnapshot(dir)
	if err != nil || len(before) == 0 {
		return nil, err
	}
	if err := restartSleep(dir); err != nil {
		return nil, err
	}
	after, err := containerRestartSnapshot(dir)
	if err != nil {
		return nil, err
	}
	if len(after) == 0 {
		return nil, errRestartObservation
	}
	return restartedNames(before, after)
}

func containerRestartSnapshot(dir string) ([]restartRow, error) {
	engine, err := networkTool(host.Engine())
	if err != nil {
		return nil, err
	}
	if engine == "" {
		return nil, errRestartObservation
	}
	idsOutput, err := restartCommand(dir, engine, "compose", "ps", "-aq")
	if errors.Is(err, ErrUnsupportedProbeInput) {
		return nil, err
	}
	if err != nil {
		return nil, errRestartObservation
	}
	ids, err := restartIDs(idsOutput)
	if err != nil {
		return nil, err
	}
	if len(ids) == 0 && strings.TrimRight(idsOutput, "\n") == "" {
		return nil, nil
	}
	args := append([]string{"inspect", "--format", restartInspectFormat}, ids...)
	rowsOutput, err := restartCommand(dir, engine, args...)
	if errors.Is(err, ErrUnsupportedProbeInput) {
		return nil, err
	}
	if err != nil {
		return nil, errRestartObservation
	}
	return parseRestartRows(rowsOutput)
}

func restartCommand(dir, name string, args ...string) (string, error) {
	command := exec.Command(name, args...)
	command.Dir = dir
	output, err := command.Output()
	if unsupportedLaunch(err) {
		return "", ErrUnsupportedProbeInput
	}
	if strings.ContainsRune(string(output), 0) {
		return "", ErrUnsupportedProbeInput
	}
	return strings.TrimRight(string(output), "\n"), err
}

func restartSleep(dir string) error {
	sleep, err := networkTool("sleep")
	if err != nil || sleep == "" {
		return ErrUnsupportedProbeInput
	}
	var stdout, stderr bytes.Buffer
	command := exec.Command(sleep, "3")
	command.Dir = dir
	command.Stdout = &stdout
	command.Stderr = &stderr
	runErr := command.Run()
	if unsupportedLaunch(runErr) || stdout.Len() != 0 || stderr.Len() != 0 {
		return ErrUnsupportedProbeInput
	}
	return nil
}

func restartIDs(value string) ([]string, error) {
	value = strings.TrimRight(value, "\n")
	fields := make([]string, 0)
	start := -1
	for index := 0; index <= len(value); index++ {
		separator := index == len(value) || value[index] == ' ' || value[index] == '\t' || value[index] == '\n'
		if separator {
			if start >= 0 {
				fields = append(fields, value[start:index])
				start = -1
			}
			continue
		}
		if value[index] >= 0x80 || strings.ContainsRune("*?[", rune(value[index])) {
			return nil, ErrUnsupportedProbeInput
		}
		if start < 0 {
			start = index
		}
	}
	return fields, nil
}

func parseRestartRows(value string) ([]restartRow, error) {
	value = strings.TrimRight(value, "\n")
	rows := make([]restartRow, 0)
	for _, line := range strings.Split(value, "\n") {
		fields := restartTSVFields(line, 5)
		if fields == nil || !restartIDPattern.MatchString(fields[0]) || fields[1] == "" || fields[2] == "" ||
			!restartCountPattern.MatchString(fields[3]) || fields[4] == "" {
			return nil, errRestartObservation
		}
		rows = append(rows, restartRow{fields[0], fields[1], fields[2], fields[3], fields[4]})
	}
	return rows, nil
}

func restartTSVFields(line string, count int) []string {
	line = strings.Trim(line, "\t")
	fields := make([]string, 0, count)
	for len(fields) < count-1 {
		separator := strings.IndexByte(line, '\t')
		if separator < 0 {
			return nil
		}
		fields = append(fields, line[:separator])
		line = strings.TrimLeft(line[separator:], "\t")
	}
	return append(fields, line)
}

func restartedNames(before, after []restartRow) ([]string, error) {
	counts := make(map[string]string, len(before))
	started := make(map[string]string, len(before))
	names := make(map[string]string, len(before))
	reported := make(map[string]bool)
	result := make([]string, 0)
	for _, row := range before {
		name := restartContainerName(row.name)
		counts[row.id] = row.count
		started[row.id] = row.started
		names[row.id] = name
		if row.state == "restarting" {
			if name == "" {
				return nil, ErrUnsupportedProbeInput
			}
			result = append(result, name)
			reported[name] = true
		}
	}
	for _, row := range after {
		name := restartContainerName(row.name)
		if row.state == "restarting" {
			if name == "" {
				return nil, ErrUnsupportedProbeInput
			}
			if !reported[name] {
				result = append(result, name)
				reported[name] = true
			}
			continue
		}
		beforeCount, exists := counts[row.id]
		if !exists {
			continue
		}
		increased, err := restartCountIncreased(row.count, beforeCount)
		if err != nil {
			return nil, err
		}
		if increased || (!strings.HasPrefix(started[row.id], "0001-01-01") && row.started != started[row.id]) {
			name = names[row.id]
			if name == "" {
				return nil, ErrUnsupportedProbeInput
			}
			if !reported[name] {
				result = append(result, name)
				reported[name] = true
			}
		}
	}
	return result, nil
}

func restartContainerName(name string) string {
	name = strings.TrimPrefix(name, "/")
	if match := restartComposePattern.FindStringSubmatch(name); match != nil {
		return match[1]
	}
	return name
}

func restartCountIncreased(after, before string) (bool, error) {
	a, err := strconv.ParseInt(after, 10, 64)
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	b, err := strconv.ParseInt(before, 10, 64)
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	return a > b, nil
}
