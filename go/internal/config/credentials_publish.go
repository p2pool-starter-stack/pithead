package config

import (
	"errors"
	"os"
)

var ErrUnsupportedCredentialTarget = errors.New("unsupported credential target")

func PublishNodeCredentials(raw []byte, path, username, password string) error {
	return publishNodeCredentials(raw, path, username, password, os.Rename)
}

func publishNodeCredentials(raw []byte, path, username, password string, rename func(string, string) error) error {
	rendered, err := PersistNodeCredentials(raw, username, password)
	if err != nil {
		return err
	}
	source, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if source.Mode()&os.ModeSymlink != 0 {
		resolved, resolveErr := os.Stat(path)
		if resolveErr != nil || !resolved.Mode().IsRegular() {
			return ErrUnsupportedCredentialTarget
		}
	} else if !source.Mode().IsRegular() {
		return ErrUnsupportedCredentialTarget
	}
	stagePath := path + ".tmp"
	if _, err := os.Lstat(stagePath); err == nil || !errors.Is(err, os.ErrNotExist) {
		return ErrUnsupportedCredentialTarget
	}
	stage, err := os.OpenFile(stagePath, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0o600)
	if err != nil {
		return err
	}
	committed := false
	defer func() {
		if !committed {
			stage.Close()
			os.Remove(stagePath)
		}
	}()
	if err := stage.Chmod(0o600); err != nil {
		return err
	}
	info, err := stage.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Mode().Perm() != 0o600 {
		return ErrUnsupportedCredentialTarget
	}
	if written, writeErr := stage.Write(rendered); writeErr != nil || written != len(rendered) {
		if writeErr != nil {
			return writeErr
		}
		return ErrUnsupportedCredentialTarget
	}
	if err := stage.Close(); err != nil {
		return err
	}
	if err := rename(stagePath, path); err != nil {
		return err
	}
	committed = true
	return nil
}
