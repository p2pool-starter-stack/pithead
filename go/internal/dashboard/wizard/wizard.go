package wizard

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"unicode"
	"unicode/utf8"
)

type Request struct {
	Operation string `json:"operation"`
	Spool     string `json:"spool"`
	Handoff   string `json:"handoff"`
	Name      string `json:"name"`
	Directory string `json:"directory"`
}

type Error struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
	Errno   any    `json:"errno"`
}

type Response struct {
	OK    bool
	Value json.RawMessage
	Error *Error
}

func (r Response) MarshalJSON() ([]byte, error) {
	if !r.OK {
		return json.Marshal(struct {
			OK    bool   `json:"ok"`
			Error *Error `json:"error"`
		}{r.OK, r.Error})
	}
	value := r.Value
	if len(value) == 0 {
		value = json.RawMessage("null")
	}
	return append(append([]byte(`{"ok":true,"value":`), value...), '}'), nil
}

func Handle(request Request) Response {
	view := View{Spool: request.Spool, Handoff: request.Handoff}
	if view.Handoff == "" {
		view.Handoff = view.Spool
	}
	var value any
	var raw json.RawMessage
	var err error
	switch request.Operation {
	case "stage":
		value, err = view.Stage()
	case "installer":
		value, err = view.InstallerMode()
	case "status":
		value, err = view.Status()
	case "reference":
		raw, err = view.Reference()
	case "last-attempt":
		raw, err = view.Object("last-attempt.json")
	case "rig-defaults":
		raw, err = view.Object("rig-defaults.json")
	case "data-wiped":
		raw, err = view.Object("data-wiped.json")
	case "saved-role":
		raw, err = view.SavedRole()
	case "read":
		value, err = view.Read(request.Name, request.Directory)
	default:
		err = fmt.Errorf("unsupported wizard operation: %s", request.Operation)
	}
	if err != nil {
		return Response{Error: wireError(err)}
	}
	if raw == nil {
		raw, err = json.Marshal(value)
		if err != nil {
			return Response{Error: wireError(err)}
		}
	}
	return Response{OK: true, Value: raw}
}

type View struct {
	Spool   string
	Handoff string
}

func (v View) Read(name, directory string) (*string, error) {
	if directory == "" {
		directory = v.Spool
	}
	path := filepath.Join(directory, name)
	if _, err := os.Stat(path); err != nil {
		return nil, nil
	}
	contents, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	if !utf8.Valid(contents) {
		return nil, decodeError{path: path}
	}
	text := strings.ReplaceAll(string(contents), "\r\n", "\n")
	text = strings.ReplaceAll(text, "\r", "\n")
	text = strings.TrimFunc(text, pythonSpace)
	return &text, nil
}

func (v View) InstallerMode() (bool, error) {
	disks, err := v.Read("disks.tsv", "")
	return disks != nil, err
}

func (v View) Stage() (string, error) {
	failed, err := v.present("setup-failed", "")
	if err != nil {
		return "", err
	}
	if failed {
		return "failed", nil
	}
	installer, err := v.InstallerMode()
	if err != nil {
		return "", err
	}
	if installer {
		installError, readErr := v.present("error.txt", "")
		if readErr != nil {
			return "", readErr
		}
		if installError {
			return "failed", nil
		}
	}
	handoffDirectory := v.Handoff
	if handoffDirectory == "" {
		handoffDirectory = v.Spool
	}
	handoff, err := v.present("handoff.json", handoffDirectory)
	if err != nil {
		return "", err
	}
	if handoff {
		ack, readErr := v.present("handoff-ack", "")
		if readErr != nil {
			return "", readErr
		}
		if !ack {
			return "handoff", nil
		}
	}
	installed, err := v.present("installed", "")
	if err != nil {
		return "", err
	}
	if installed {
		return "installing", nil
	}
	installing, err := v.present("installing", "")
	if err != nil {
		return "", err
	}
	if installing {
		return "installing", nil
	}
	applied, err := v.present("applied", "")
	if err != nil {
		return "", err
	}
	if !applied {
		applied, err = v.present("handoff-ack", "")
		if err != nil {
			return "", err
		}
	}
	if applied {
		installer, readErr := v.InstallerMode()
		if readErr != nil {
			return "", readErr
		}
		if installer {
			stick, stickErr := v.Read("stick", "")
			if stickErr != nil {
				return "", stickErr
			}
			if stick == nil || *stick != "1" {
				return "installing", nil
			}
		}
		return "done", nil
	}
	installer, err = v.InstallerMode()
	if err != nil {
		return "", err
	}
	if installer {
		return "installer", nil
	}
	return "setup", nil
}

func (v View) Status() (string, error) {
	installer, err := v.InstallerMode()
	if err != nil {
		return "", err
	}
	if installer {
		stick, readErr := v.Read("stick", "")
		if readErr != nil {
			return "", readErr
		}
		if stick != nil && *stick == "1" {
			return v.inPlaceStatus()
		}
		installed, readErr := v.present("installed", "")
		if readErr != nil {
			return "", readErr
		}
		if installed {
			return "Installed — the machine is switching itself off. Wait for it to go dark, then remove the USB stick and power it back on.", nil
		}
		message, readErr := v.Read("error.txt", "")
		if readErr != nil {
			return "", readErr
		}
		if message != nil {
			return "Install failed: " + *message, nil
		}
		return "Copying the system to the disk…", nil
	}
	return v.inPlaceStatus()
}

func (v View) inPlaceStatus() (string, error) {
	applied, err := v.present("applied", "")
	if err != nil {
		return "", err
	}
	if applied {
		role, readErr := v.Read("role", "")
		if readErr != nil {
			return "", readErr
		}
		if role != nil && *role == "rig" {
			return "Rig settings saved. The miner is starting on this machine now — it appears in your Pithead's Workers view once it connects.", nil
		}
		return "Provisioned — the dashboard is coming up now.", nil
	}
	message, err := v.Read("error.txt", "")
	if err != nil {
		return "", err
	}
	if message != nil {
		return "Rejected: " + *message + " — go back and correct the form.", nil
	}
	return "Waiting for this machine to validate and apply…", nil
}

func (v View) Reference() (json.RawMessage, error) {
	object, err := v.object("config.reference.json")
	if err != nil {
		return nil, err
	}
	return object.without(func(key string) bool {
		return strings.HasPrefix(key, "_") || key == "config_version"
	}), nil
}

func (v View) Object(name string) (json.RawMessage, error) {
	object, err := v.object(name)
	if err != nil {
		return nil, err
	}
	return object.raw(), nil
}

func (v View) SavedRole() (json.RawMessage, error) {
	object, err := v.object("saved-role.json")
	if err != nil {
		return nil, err
	}
	role, ok := object.stringValue("role")
	if !ok || role == "" {
		return json.RawMessage("null"), nil
	}
	return object.raw(), nil
}

func (v View) object(name string) (rawObject, error) {
	text, err := v.Read(name, "")
	if err != nil {
		var decoding decodeError
		if errors.As(err, &decoding) {
			return emptyObject(), nil
		}
		return rawObject{}, err
	}
	if text == nil || *text == "" {
		return emptyObject(), nil
	}
	object, ok := parseObject([]byte(*text))
	if !ok {
		return emptyObject(), nil
	}
	return object, nil
}

func (v View) present(name, directory string) (bool, error) {
	value, err := v.Read(name, directory)
	return value != nil, err
}

type decodeError struct{ path string }

func (e decodeError) Error() string {
	return fmt.Sprintf("'utf-8' codec can't decode file %q", e.path)
}

func wireError(err error) *Error {
	kind := "OSError"
	var decoding decodeError
	if errors.As(err, &decoding) {
		kind = "UnicodeDecodeError"
	}
	var syntax *json.SyntaxError
	var valueType *json.UnmarshalTypeError
	if errors.As(err, &syntax) || errors.As(err, &valueType) || strings.HasPrefix(err.Error(), "unsupported wizard operation") {
		kind = "ValueError"
	}
	var errno any
	var pathError *os.PathError
	if errors.As(err, &pathError) {
		var number syscall.Errno
		if errors.As(pathError.Err, &number) {
			errno = int(number)
		}
	}
	return &Error{Kind: kind, Message: err.Error(), Errno: errno}
}

func pythonSpace(r rune) bool {
	return unicode.IsSpace(r) || r >= 0x1c && r <= 0x1f
}
