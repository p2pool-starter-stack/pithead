package wizard

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"syscall"
)

var transactionFiles = []string{
	"restore-archive",
	"restore-inflight",
	"install-attempt.json",
	"install-request",
	"submission-staging",
	"submission-active",
	"config.json",
	"rig-request.json",
}

var submissionSidecars = []string{"auth-mode", "role"}

var rollbackFiles = append(
	append(append([]string{}, transactionFiles...), submissionSidecars...),
	"last-attempt.json",
)

var pageTempFiles = append(append([]string{}, rollbackFiles...), "restore-passphrase")

type transactionIO interface {
	Replace(string, string) error
	Unlink(string) error
}

type systemTransactionIO struct{}

func (systemTransactionIO) Replace(source, destination string) error {
	return os.Rename(source, destination)
}

func (systemTransactionIO) Unlink(path string) error {
	return syscall.Unlink(path)
}

type Txn struct {
	Spool   string
	Restore string
	IO      transactionIO
}

func handleTransaction(request Request, transactionIO transactionIO) (any, error) {
	txn := Txn{Spool: request.Spool, Restore: request.Restore, IO: transactionIO}
	switch request.Operation {
	case "write":
		return nil, txn.Write(request.Name, request.Data, request.Directory)
	case "remove":
		return nil, txn.Remove(request.Name, request.Directory)
	case "exists":
		return txn.Exists(request.Name, request.Directory), nil
	case "conflict":
		return txn.Conflict(), nil
	case "clear-sidecars":
		return nil, txn.ClearSidecars()
	case "clear-restore":
		return txn.ClearRestore(), nil
	case "clear-temps":
		return txn.ClearTemps(), nil
	default:
		return nil, fmt.Errorf("unsupported wizard operation: %s", request.Operation)
	}
}

func (t Txn) directory(directory string) string {
	if directory != "" {
		return directory
	}
	return t.Spool
}

func (t Txn) Write(name string, data []byte, directory string) error {
	return t.WriteStream(name, bytes.NewReader(data), int64(len(data)), directory)
}

func (t Txn) WriteStream(name string, input io.Reader, length int64, directory string) error {
	if length < 0 {
		return fmt.Errorf("invalid wizard write length: %d", length)
	}
	directory = t.directory(directory)
	if err := os.MkdirAll(directory, 0o777); err != nil {
		return err
	}
	file, err := os.CreateTemp(directory, "."+name+".*")
	if err != nil {
		return err
	}
	temporary := file.Name()
	if _, err = io.CopyN(file, input, length); err == nil {
		err = file.Close()
	}
	if err == nil {
		err = t.IO.Replace(temporary, transactionJoin(directory, name))
	}
	if err == nil {
		return nil
	}
	_ = file.Close()
	if cleanupErr := t.removePath(temporary); cleanupErr != nil {
		return cleanupErr
	}
	return err
}

func (t Txn) Remove(name, directory string) error {
	return t.removePath(transactionJoin(t.directory(directory), name))
}

func (t Txn) removePath(path string) error {
	err := t.IO.Unlink(path)
	if errors.Is(err, os.ErrNotExist) || errors.Is(err, syscall.ENOENT) {
		return nil
	}
	return err
}

func (t Txn) Exists(name, directory string) bool {
	return t.existsPath(transactionJoin(t.directory(directory), name))
}

func (t Txn) existsPath(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func (t Txn) Conflict() any {
	if t.Exists("restore-archive", "") || t.Exists("restore-inflight", "") || t.existsPath(transactionJoin(t.Restore, "restore-archive")) {
		return conflict(409, "another setup submission is already being processed")
	}
	if t.existsPath(transactionJoin(t.Restore, "restore-passphrase")) && !t.ClearRestore() {
		return conflict(500, "an incomplete restore submission could not be cleared safely")
	}
	for _, name := range append(append([]string{}, transactionFiles...), "installing") {
		if t.Exists(name, "") {
			return conflict(409, "another setup submission is already being processed")
		}
	}
	return nil
}

func conflict(status int, message string) map[string]any {
	return map[string]any{"status": status, "error": message}
}

func (t Txn) ClearSidecars() error {
	for _, name := range submissionSidecars {
		if err := t.Remove(name, ""); err != nil {
			return err
		}
	}
	return nil
}

func (t Txn) ClearRestore() bool {
	ok := true
	for _, target := range []struct{ name, directory string }{
		{"restore-passphrase", t.Restore},
		{"restore-archive", t.Restore},
	} {
		if err := t.Remove(target.name, target.directory); err != nil {
			ok = false
		}
	}
	for _, name := range rollbackFiles {
		if err := t.Remove(name, ""); err != nil {
			ok = false
		}
	}
	return t.ClearTemps() && ok
}

func (t Txn) ClearTemps() bool {
	ok := true
	for _, directory := range []string{t.Spool, t.Restore} {
		file, err := os.OpenFile(directory, os.O_RDONLY|syscall.O_DIRECTORY, 0)
		if errors.Is(err, os.ErrNotExist) {
			continue
		}
		if err != nil {
			ok = false
			continue
		}
		names, readErr := file.Readdirnames(-1)
		_ = file.Close()
		if readErr != nil {
			ok = false
			continue
		}
		for _, name := range names {
			if !isPageTemp(name) {
				continue
			}
			path := transactionJoin(directory, name)
			info, statErr := os.Lstat(path)
			if errors.Is(statErr, os.ErrNotExist) {
				continue
			}
			if statErr != nil || info.Mode()&os.ModeType != 0 && info.Mode()&os.ModeSymlink == 0 {
				ok = false
				continue
			}
			if err := t.removePath(path); err != nil {
				ok = false
			}
		}
	}
	return ok
}

func isPageTemp(name string) bool {
	for _, target := range pageTempFiles {
		if len(name) >= len(target)+2 && name[:len(target)+2] == "."+target+"." {
			return true
		}
	}
	return false
}

func transactionJoin(directory, name string) string {
	if filepath.IsAbs(name) || directory == "" {
		return name
	}
	if directory[len(directory)-1] == os.PathSeparator {
		return directory + name
	}
	return directory + string(os.PathSeparator) + name
}
