package config

import (
	"encoding/json"
	"errors"
	"strconv"
	"strings"
)

var ErrUnsupportedVersion = errors.New("unsupported config version")

type VersionPlan struct {
	Stamp        string
	Newer        bool
	Malformed    bool
	EqualPresent bool
}

func NormalizeCodeVersion(raw string) (string, bool, error) {
	if !asciiVersionInput(raw) {
		return "", false, ErrUnsupportedVersion
	}
	if boundary := strings.IndexAny(raw, "-+"); boundary >= 0 {
		raw = raw[:boundary]
	}
	valid, err := ConfigVersionOK(raw)
	return raw, valid, err
}

func ConfigVersionOK(version string) (bool, error) {
	if !asciiVersionInput(version) {
		return false, ErrUnsupportedVersion
	}
	parts := strings.Split(version, ".")
	if len(parts) != 3 {
		return false, nil
	}
	for _, part := range parts {
		if len(part) < 1 || len(part) > 4 {
			return false, nil
		}
		for index := range part {
			if part[index] < '0' || part[index] > '9' {
				return false, nil
			}
		}
	}
	return true, nil
}

func PlanConfigVersion(raw []byte, version string) (VersionPlan, error) {
	valid, err := ConfigVersionOK(version)
	if err != nil || !valid {
		return VersionPlan{}, ErrUnsupportedVersion
	}
	document, err := ParseDocument(raw)
	if err != nil || document == nil || document.root.object == nil || duplicateError(document.root, "") != "" {
		return VersionPlan{}, ErrUnsupportedVersion
	}
	stamp := "2.0.0"
	present := false
	if value, ok := objectValue(document.root, "config_version"); ok {
		if value.object != nil || value.array != nil {
			return VersionPlan{}, ErrUnsupportedVersion
		}
		switch typed := value.value.(type) {
		case nil:
		case bool:
			if typed {
				stamp = "true"
			}
		case string:
			if !asciiVersionInput(typed) {
				return VersionPlan{}, ErrUnsupportedVersion
			}
			stamp = typed
			present = typed == version
		case json.Number:
			stamp = typed.String()
		default:
			return VersionPlan{}, ErrUnsupportedVersion
		}
	}
	stampValid, err := ConfigVersionOK(stamp)
	if err != nil {
		return VersionPlan{}, err
	}
	return VersionPlan{
		Stamp:        stamp,
		Newer:        stampValid && semverNewer(stamp, version),
		Malformed:    !stampValid,
		EqualPresent: present,
	}, nil
}

func StampConfigVersion(raw []byte, version string) ([]byte, error) {
	valid, err := ConfigVersionOK(version)
	if err != nil || !valid {
		return nil, ErrUnsupportedVersion
	}
	document, err := ParseDocument(raw)
	if err != nil || document == nil || document.root.object == nil || duplicateError(document.root, "") != "" {
		return nil, ErrUnsupportedVersion
	}
	root := cloneNode(document.root)
	if err := setStringPath(&root, "config_version", node{value: version}); err != nil {
		return nil, ErrUnsupportedVersion
	}
	rendered, err := prettyJQ(root)
	if err != nil {
		return nil, ErrUnsupportedVersion
	}
	return rendered, nil
}

func asciiVersionInput(value string) bool {
	for index := range value {
		if value[index] < 0x20 || value[index] > 0x7e {
			return false
		}
	}
	return true
}

func semverNewer(left, right string) bool {
	leftParts := strings.Split(left, ".")
	rightParts := strings.Split(right, ".")
	for index := range 3 {
		leftValue, _ := strconv.Atoi(leftParts[index])
		rightValue, _ := strconv.Atoi(rightParts[index])
		if leftValue != rightValue {
			return leftValue > rightValue
		}
	}
	return false
}
