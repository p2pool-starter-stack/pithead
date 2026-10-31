package cli

import (
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"syscall"

	"github.com/p2pool-starter-stack/pithead/go/internal/help"
)

type ExitError struct {
	Code    int
	Message string
	Signal  syscall.Signal
}

func (e *ExitError) Error() string {
	return e.Message
}

func writeHelp(w io.Writer, reference string) error {
	sigpipe := make(chan os.Signal, 1)
	signal.Notify(sigpipe, syscall.SIGPIPE)
	defer signal.Stop(sigpipe)
	err := help.Write(w, reference)
	if errors.Is(err, syscall.EPIPE) {
		return &ExitError{
			Code:    141,
			Message: fmt.Sprintf("[ERROR] pithead aborted unexpectedly (exit 141).\nRe-run with 'bash -x %s <command>' to see where, and check the output above.", reference),
		}
	}
	return err
}
