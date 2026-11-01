package cli

import (
	"os"
	"os/exec"
	"strings"
	"syscall"
)

func fallback(reference string, args []string) error {
	bash, err := exec.LookPath("bash")
	if err != nil {
		return err
	}
	binary, err := os.Executable()
	if err != nil {
		return err
	}
	env := configDocumentFallbackEnv(fallbackEnv(os.Environ()), binary)
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
