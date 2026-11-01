package config

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"syscall"
)

var ErrUnsupportedTariSecret = errors.New("unsupported Tari secret publication")

func PublishTariSecret(path string, targetUID, targetGID uint32, view, spend, password string) error {
	if uint32(os.Geteuid()) != targetUID {
		return ErrUnsupportedTariSecret
	}
	return publishTariSecret(path, targetUID, targetGID, view, spend, password, false)
}

func PublishTariSecretWithOwnership(path string, targetUID, targetGID uint32, view, spend, password string) error {
	return publishTariSecret(path, targetUID, targetGID, view, spend, password, true)
}

func publishTariSecret(path string, targetUID, targetGID uint32, view, spend, password string, repair bool) error {
	if info, err := os.Stat(path); err == nil {
		if info.IsDir() {
			return ErrUnsupportedTariSecret
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return err
	}
	directory := filepath.Dir(path)
	file, err := os.CreateTemp(directory, ".tari-wallet-secret.")
	if err != nil {
		return err
	}
	temporary := file.Name()
	published := false
	defer func() {
		if !published {
			file.Close()
			os.Remove(temporary)
		}
	}()
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	content := fmt.Sprintf("MINOTARI_WALLET_VIEW_PRIVATE_KEY=%s\nMINOTARI_WALLET_SPEND_KEY=%s\nMINOTARI_WALLET_PASSWORD=%s\n", view, spend, password)
	if _, err := file.WriteString(content); err != nil {
		return err
	}
	info, err := file.Stat()
	if err != nil {
		return err
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return ErrUnsupportedTariSecret
	}
	if stat.Uid != targetUID {
		if !repair || targetUID == ^uint32(0) || targetGID == ^uint32(0) {
			return ErrUnsupportedTariSecret
		}
		if err := file.Chown(int(targetUID), int(targetGID)); err != nil {
			return err
		}
		info, err = file.Stat()
		if err != nil {
			return err
		}
		stat, ok = info.Sys().(*syscall.Stat_t)
		if !ok || stat.Uid != targetUID || stat.Gid != targetGID {
			return ErrUnsupportedTariSecret
		}
	}
	if err := file.Close(); err != nil {
		return err
	}
	if err := os.Rename(temporary, path); err != nil {
		return err
	}
	published = true
	return nil
}
