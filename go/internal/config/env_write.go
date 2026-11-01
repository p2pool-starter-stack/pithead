package config

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

var ErrUnsupportedEnvTarget = errors.New("unsupported env target")

func WriteEnv(path string, body []byte) error {
	if info, err := os.Lstat(path); err == nil {
		if !info.Mode().IsRegular() {
			return ErrUnsupportedEnvTarget
		}
	} else if errors.Is(err, os.ErrNotExist) {
		parent, parentErr := os.Stat(filepath.Dir(path))
		if parentErr != nil || !parent.IsDir() {
			return ErrUnsupportedEnvTarget
		}
	} else {
		return err
	}
	fd, err := syscall.Open(path, syscall.O_WRONLY|syscall.O_CREAT|syscall.O_TRUNC|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0o600)
	if err != nil {
		return err
	}
	file := os.NewFile(uintptr(fd), path)
	if file == nil {
		syscall.Close(fd)
		return ErrUnsupportedEnvTarget
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil {
		return err
	}
	if !info.Mode().IsRegular() {
		return ErrUnsupportedEnvTarget
	}
	payload := make([]byte, len(body)+1)
	copy(payload, body)
	payload[len(body)] = '\n'
	if _, err := file.Write(payload); err != nil {
		return err
	}
	return file.Close()
}
