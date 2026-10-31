package status

import (
	"errors"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
)

type restartSnapshot struct {
	id      string
	name    string
	state   string
	count   string
	started string
}

var (
	restartIDPattern    = regexp.MustCompile(`^[0-9a-f]+$`)
	restartCountPattern = regexp.MustCompile(`^[0-9]+$`)
	composeNamePattern  = regexp.MustCompile(`^[0-9a-f]{12}_(.+)$`)
)

func (r *Runner) restartingNames() ([]string, error) {
	before, err := r.restartSnapshot()
	if err != nil || len(before) == 0 {
		return nil, err
	}
	if _, err := r.output("sleep", "3"); err != nil {
		return nil, err
	}
	after, err := r.restartSnapshot()
	if err != nil {
		return nil, err
	}
	if len(after) == 0 {
		return nil, errors.New("container restart snapshot became empty")
	}

	counts := make(map[string]string, len(before))
	started := make(map[string]string, len(before))
	names := make(map[string]string, len(before))
	reported := make(map[string]bool)
	var result []string
	for _, row := range before {
		name := restartName(row.name)
		counts[row.id] = row.count
		started[row.id] = row.started
		names[row.id] = name
		if row.state == "restarting" {
			result = append(result, name)
			reported[name] = true
		}
	}
	for _, row := range after {
		name := restartName(row.name)
		if row.state == "restarting" {
			if !reported[name] {
				result = append(result, name)
				reported[name] = true
			}
			continue
		}
		beforeCount, ok := counts[row.id]
		if !ok {
			continue
		}
		if signedCountGreater(row.count, beforeCount) ||
			(!strings.HasPrefix(started[row.id], "0001-01-01") && row.started != started[row.id]) {
			name = names[row.id]
			if !reported[name] {
				result = append(result, name)
				reported[name] = true
			}
		}
	}
	return result, nil
}

func (r *Runner) restartSnapshot() ([]restartSnapshot, error) {
	engine := containerEngine()
	if _, err := exec.LookPath(engine); err != nil {
		return nil, err
	}
	ids, err := r.output(engine, "compose", "ps", "-aq")
	if err != nil {
		return nil, err
	}
	fields := strings.Fields(ids)
	if len(fields) == 0 {
		return nil, nil
	}
	args := []string{"inspect", "--format", "{{.Id}}\t{{.Name}}\t{{.State.Status}}\t{{.RestartCount}}\t{{.State.StartedAt}}"}
	rows, err := r.output(engine, append(args, fields...)...)
	if err != nil {
		return nil, err
	}
	if rows == "" {
		return nil, errors.New("empty container restart snapshot")
	}
	result := make([]restartSnapshot, 0)
	for _, line := range strings.Split(rows, "\n") {
		parts := shellTSVFields(line, 5)
		if parts == nil || !restartIDPattern.MatchString(parts[0]) || parts[1] == "" || parts[2] == "" ||
			!restartCountPattern.MatchString(parts[3]) || parts[4] == "" {
			return nil, errors.New("malformed container restart snapshot")
		}
		result = append(result, restartSnapshot{parts[0], parts[1], parts[2], parts[3], parts[4]})
	}
	return result, nil
}

func shellTSVFields(line string, count int) []string {
	line = strings.Trim(line, "\t")
	result := make([]string, 0, count)
	for len(result) < count-1 {
		separator := strings.IndexByte(line, '\t')
		if separator < 0 {
			return nil
		}
		result = append(result, line[:separator])
		line = strings.TrimLeft(line[separator:], "\t")
	}
	return append(result, line)
}

func containerEngine() string {
	if engine := os.Getenv("PITHEAD_ENGINE"); engine == "docker" || engine == "podman" {
		return engine
	}
	if _, err := exec.LookPath("docker"); err == nil {
		return "docker"
	}
	if _, err := exec.LookPath("podman"); err == nil {
		return "podman"
	}
	return "docker"
}

func restartName(name string) string {
	name = strings.TrimPrefix(name, "/")
	if match := composeNamePattern.FindStringSubmatch(name); match != nil {
		return match[1]
	}
	return name
}

func signedCountGreater(after, before string) bool {
	a, err := strconv.ParseInt(after, 10, 64)
	if err != nil {
		return false
	}
	b, err := strconv.ParseInt(before, 10, 64)
	return err == nil && a > b
}
