package cli

import (
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
	"github.com/p2pool-starter-stack/pithead/go/internal/status"
)

var ErrFallback = errors.New("use Bash CLI")

type ExitError struct {
	Code    int
	Message string
}

func (e *ExitError) Error() string {
	return e.Message
}

func Run(reference string, args []string, stdout io.Writer) error {
	command := nativeCommand(args)
	if command == "" {
		return ErrFallback
	}
	if file, ok := stdout.(*os.File); ok {
		if _, err := file.Stat(); err != nil {
			return ErrFallback
		}
	}
	if command == "help" {
		return writeHelp(stdout, reference)
	}
	dir, err := referenceDir(reference)
	if err != nil {
		return ErrFallback
	}
	if command == "version" {
		if err := writeVersion(stdout, dir); err != nil {
			return ErrFallback
		}
		return nil
	}
	if !statusReady() {
		return ErrFallback
	}
	envFile := os.Getenv("PITHEAD_ENV_FILE")
	if envFile == "" {
		envFile = ".env"
	}
	runner := status.Runner{Dir: dir, Program: reference, EnvFile: envFile, Out: stdout, Err: os.Stderr}
	code := runner.Run()
	if code != 0 {
		return &ExitError{Code: code}
	}
	return nil
}

func Fallback(reference string, args []string) error {
	bash, argv, env, err := fallbackInvocation(reference, args)
	if err != nil {
		return err
	}
	return syscall.Exec(bash, argv, env)
}

func fallbackInvocation(reference string, args []string) (string, []string, []string, error) {
	bash, err := exec.LookPath("bash")
	if err != nil {
		return "", nil, nil, err
	}
	return bash, append([]string{"bash", reference}, args...), os.Environ(), nil
}

func nativeCommand(args []string) string {
	if len(args) != 1 {
		return ""
	}
	switch args[0] {
	case "help", "-h", "--help":
		return "help"
	case "version", "-V", "--version":
		return "version"
	case "status":
		return "status"
	default:
		return ""
	}
}

func referenceDir(reference string) (string, error) {
	dir, err := filepath.Abs(filepath.Dir(reference))
	if err != nil {
		return "", err
	}
	return filepath.EvalSymlinks(dir)
}

func statusReady() bool {
	if !status.LocaleSupported() {
		return false
	}
	for _, name := range []string{"docker", host.Engine(), "jq", "curl", "sleep", "openssl"} {
		if _, err := exec.LookPath(name); err != nil {
			return false
		}
	}
	return true
}
