package doctor

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"strings"
	"syscall"
	"unsafe"
)

var ErrFallback = errors.New("doctor requires Bash fallback")
var ErrProbeAborted = errors.New("doctor probe exited before returning")

type SignalError struct {
	Signal syscall.Signal
}

func (e *SignalError) Error() string { return e.Signal.String() }

type Runner struct {
	Reference, Version string
	Env                []string
	Out, Err           io.Writer
}

func (r Runner) RunJSON() (int, error) {
	if file, ok := r.Out.(*os.File); ok {
		var size [4]uint16
		_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, file.Fd(), uintptr(syscall.TIOCGWINSZ), uintptr(unsafe.Pointer(&size)))
		if errno == 0 {
			return 0, ErrFallback
		}
	}
	if _, err := exec.LookPath("jq"); err != nil {
		return 0, ErrFallback
	}
	bash, err := exec.LookPath("bash")
	if err != nil {
		return 0, ErrFallback
	}
	rows, err := os.CreateTemp("", "pithead-doctor-*")
	if err != nil {
		return 0, ErrFallback
	}
	defer os.Remove(rows.Name())
	defer os.Remove(rows.Name() + ".done")
	if err := rows.Close(); err != nil {
		return 0, ErrFallback
	}
	cmd := exec.Command(bash, r.Reference, "doctor")
	cmd.Env = probeEnv(r.Env, rows.Name())
	cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, r.Err, r.Err
	code := 0
	if err := runProbe(cmd); err != nil {
		var interrupted *SignalError
		if errors.As(err, &interrupted) {
			return 128 + int(interrupted.Signal), err
		}
		var exit *exec.ExitError
		if !errors.As(err, &exit) {
			return 0, err
		}
		code = exit.ExitCode()
		if status, ok := exit.Sys().(syscall.WaitStatus); ok && status.Signaled() {
			return 128 + int(status.Signal()), &SignalError{Signal: status.Signal()}
		}
	}
	if _, err := os.Stat(rows.Name() + ".done"); err != nil {
		return code, ErrProbeAborted
	}
	data, err := os.ReadFile(rows.Name())
	if err != nil {
		return 0, err
	}
	sigpipe := make(chan os.Signal, 1)
	signal.Notify(sigpipe, syscall.SIGPIPE)
	defer signal.Stop(sigpipe)
	err = WriteJSON(r.Out, r.Version, code, data)
	if errors.Is(err, syscall.EPIPE) {
		err = nil
	}
	return code, err
}

func runProbe(cmd *exec.Cmd) error {
	signals := make(chan os.Signal, 1)
	signal.Notify(signals, syscall.SIGTERM, syscall.SIGINT, syscall.SIGHUP)
	defer signal.Stop(signals)
	if err := cmd.Start(); err != nil {
		return err
	}
	done := make(chan error, 1)
	go func() { done <- cmd.Wait() }()
	var interrupted syscall.Signal
	for {
		select {
		case received := <-signals:
			interrupted = received.(syscall.Signal)
			_ = cmd.Process.Signal(received)
		case err := <-done:
			if interrupted != 0 {
				return &SignalError{Signal: interrupted}
			}
			return err
		}
	}
}

func probeEnv(env []string, rows string) []string {
	filtered := make([]string, 0, len(env)+3)
	for _, entry := range env {
		if !strings.HasPrefix(entry, "DR_JSON_FILE=") && !strings.HasPrefix(entry, "NO_COLOR=") && !strings.HasPrefix(entry, "PITHEAD_GO_DOCTOR_DONE=") {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, "DR_JSON_FILE="+rows, "NO_COLOR=1", "PITHEAD_GO_DOCTOR_DONE="+rows+".done")
}
