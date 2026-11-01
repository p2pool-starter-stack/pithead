package control

import (
	"os"
	"path/filepath"
	"strings"
)

func write(command Request) (any, error) {
	path, err := stage(command)
	if err != nil {
		return nil, err
	}
	if err := publish(command.Directory, command.ID, path); err != nil {
		_ = os.Remove(path)
		return nil, err
	}
	return command.ID, nil
}

func stage(command Request) (string, error) {
	if command.ID == "" && !command.IDPresent {
		return "", newError("KeyError", "id", nil)
	}
	data := command.Data
	if data == nil {
		data = command.Request
	}
	file, err := os.CreateTemp(command.Directory, "."+command.ID+".*.tmp")
	if err != nil {
		return "", osError(err)
	}
	path := file.Name()
	keep := false
	defer func() {
		_ = file.Close()
		if !keep {
			_ = os.Remove(path)
		}
	}()
	if _, err := file.Write(data); err != nil {
		return "", osError(err)
	}
	if err := file.Close(); err != nil {
		return "", osError(err)
	}
	keep = true
	return path, nil
}

func publish(directory, id, temp string) error {
	base := filepath.Base(temp)
	if filepath.Dir(temp) != filepath.Clean(directory) || !strings.HasPrefix(base, "."+id+".") || !strings.HasSuffix(base, ".tmp") {
		return valueError("invalid control spool temporary path")
	}
	if err := os.Rename(temp, filepath.Join(directory, id+".json")); err != nil {
		return osError(err)
	}
	return nil
}
