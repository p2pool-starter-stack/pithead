//go:build darwin || linux

package web

import (
	"os"
	"syscall"
)

func openFile(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NONBLOCK, 0)
}
