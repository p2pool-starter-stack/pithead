package cli

import (
	"os"
	"os/exec"
	"os/signal"
	"strconv"
	"strings"
	"syscall"
)

const ignoredSignalsEnvironment = "_PITHEAD_GO_IGNORED_SIGNALS="

func fallback(reference string, args []string) error {
	bash, err := exec.LookPath("bash")
	if err != nil {
		return err
	}
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	currentEnv := os.Environ()
	env := selectedFallbackEnv(currentEnv, binary)
	ignored := inheritedIgnoredSignals(currentEnv)
	if len(ignored) > 0 {
		signal.Ignore(ignored...)
	}
	return replaceProcess(bash, append([]string{"bash", reference}, args...), env)
}

func replaceProcess(binary string, args, env []string) error {
	return syscall.Exec(binary, args, env)
}

func fallbackEnv(env []string) []string {
	filtered := make([]string, 0, len(env)+1)
	for _, entry := range env {
		if !strings.HasPrefix(entry, "PITHEAD_IMPL=") && !strings.HasPrefix(entry, "PITHEAD_GO_REFERENCE=") {
			filtered = append(filtered, entry)
		}
	}
	return append(filtered, "PITHEAD_IMPL=bash")
}

func inheritedIgnoredSignals(env []string) []os.Signal {
	for _, entry := range env {
		if !strings.HasPrefix(entry, ignoredSignalsEnvironment) {
			continue
		}
		var signals []os.Signal
		for _, value := range strings.Split(strings.TrimPrefix(entry, ignoredSignalsEnvironment), ",") {
			number, err := strconv.ParseUint(value, 10, 8)
			if err == nil && number > 0 && number <= 64 {
				signals = append(signals, syscall.Signal(number))
			}
		}
		return signals
	}
	return nil
}

func isChain(args []string) bool {
	if len(args) < 2 || args[0] == "tor-recover" {
		return false
	}
	for _, arg := range args {
		if !strings.Contains(" "+commands+" ", " "+arg+" ") {
			return false
		}
	}
	return true
}
