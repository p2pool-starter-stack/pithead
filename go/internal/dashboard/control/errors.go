package control

import (
	"errors"
	"fmt"
	"syscall"
)

type Error struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Errno   int    `json:"errno"`
	cause   error
}

func (e *Error) Error() string {
	return e.Message
}

func (e *Error) Unwrap() error {
	return e.cause
}

func newError(kind, message string, cause error) *Error {
	result := &Error{Kind: kind, Message: message, cause: cause}
	var errno syscall.Errno
	if errors.As(cause, &errno) {
		result.Errno = int(errno)
	}
	return result
}

func valueError(format string, args ...any) error {
	return newError("ValueError", fmt.Sprintf(format, args...), nil)
}

func osError(err error) error {
	return newError("OSError", err.Error(), err)
}
