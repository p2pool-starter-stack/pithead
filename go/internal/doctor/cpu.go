package doctor

import (
	"bytes"
	"errors"
	"os"
	"os/exec"
)

type CPU struct {
	OS, CPUInfo string
}

func (cpu CPU) HasAVX2() (bool, error) {
	if cpu.OS == "Darwin" {
		return darwinAVX2()
	}
	path := cpu.CPUInfo
	if path == "" {
		path = "/proc/cpuinfo"
	}
	err := exec.Command("grep", "-q", "avx2", path).Run()
	if err == nil {
		return true, nil
	}
	var status *exec.ExitError
	var missing *exec.Error
	if errors.As(err, &status) || errors.As(err, &missing) {
		return false, nil
	}
	return false, ErrUnsupportedProbeInput
}

func (cpu CPU) Finding() (Finding, error) {
	available, err := cpu.HasAVX2()
	if err != nil {
		return Finding{}, err
	}
	if available {
		return Finding{"cpu-avx2", "ok", "AVX2 supported."}, nil
	}
	return Finding{"cpu-avx2", "warn", "AVX2 not detected — mining performance will be poor (performance only, not fatal)."}, nil
}

func darwinAVX2() (bool, error) {
	if _, err := exec.LookPath("grep"); err != nil {
		return false, ErrUnsupportedProbeInput
	}
	if _, err := exec.LookPath("sysctl"); err != nil {
		return false, nil
	}
	firstRead, firstWrite, err := os.Pipe()
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	defer firstRead.Close()
	defer firstWrite.Close()
	secondRead, secondWrite, err := os.Pipe()
	if err != nil {
		return false, ErrUnsupportedProbeInput
	}
	defer secondRead.Close()
	defer secondWrite.Close()
	commands := []*exec.Cmd{
		exec.Command("sysctl", "-a"),
		exec.Command("grep", "machdep.cpu"),
		exec.Command("grep", "-q", "AVX2"),
	}
	commands[0].Stdout = firstWrite
	commands[1].Stdin, commands[1].Stdout = firstRead, secondWrite
	commands[2].Stdin = secondRead
	var filterError, matchError bytes.Buffer
	commands[1].Stderr, commands[2].Stderr = &filterError, &matchError
	started := make([]*exec.Cmd, 0, len(commands))
	for index := len(commands) - 1; index >= 0; index-- {
		if err = commands[index].Start(); err != nil {
			break
		}
		started = append(started, commands[index])
	}
	firstRead.Close()
	firstWrite.Close()
	secondRead.Close()
	secondWrite.Close()
	available := err == nil
	for _, command := range started {
		if command.Wait() != nil {
			available = false
		}
	}
	if err != nil || filterError.Len() != 0 || matchError.Len() != 0 {
		return false, ErrUnsupportedProbeInput
	}
	return available, nil
}
