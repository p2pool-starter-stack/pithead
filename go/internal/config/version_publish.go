package config

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

var ErrUnsupportedVersionTarget = errors.New("unsupported config version target")

func PublishConfigVersion(raw []byte, path, version string) error {
	return publishConfigVersion(raw, path, version, os.Rename)
}

func publishConfigVersion(raw []byte, path, version string, rename func(string, string) error) error {
	rendered, err := StampConfigVersion(raw, version)
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
			return ErrUnsupportedVersionTarget
		}
	} else if !source.Mode().IsRegular() {
		return ErrUnsupportedVersionTarget
	}
	owner, ok := source.Sys().(*syscall.Stat_t)
	if !ok || owner.Uid == ^uint32(0) || owner.Gid == ^uint32(0) {
		return ErrUnsupportedVersionTarget
	}
	temp, err := os.CreateTemp(filepath.Dir(path), filepath.Base(path)+".version.*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	committed := false
	defer func() {
		if !committed {
			temp.Close()
			os.Remove(tempPath)
		}
	}()
	if written, writeErr := temp.Write(rendered); writeErr != nil || written != len(rendered) {
		if writeErr != nil {
			return writeErr
		}
		return ErrUnsupportedVersionTarget
	}
	if err := temp.Chmod(0o600); err != nil {
		return err
	}
	if err := temp.Chown(int(owner.Uid), int(owner.Gid)); err != nil {
		return err
	}
	info, err := temp.Stat()
	if err != nil {
		return err
	}
	actualOwner, ok := info.Sys().(*syscall.Stat_t)
	if !ok || info.Mode().Perm() != 0o600 || actualOwner.Uid != owner.Uid || actualOwner.Gid != owner.Gid {
		return ErrUnsupportedVersionTarget
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := rename(tempPath, path); err != nil {
		return err
	}
	committed = true
	return nil
}
