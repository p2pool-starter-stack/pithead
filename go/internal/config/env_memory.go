package config

import (
	"errors"
	"strconv"
)

var ErrUnsupportedMemory = errors.New("unsupported memory environment settings")

func MemorySettings(raw []byte, tariMode string) (string, string, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return "", "", ErrUnsupportedMemory
	}

	tari := "0m"
	if tariMode == "local" {
		tari, err = memoryAlternative(document.root, "tari.mem_limit", "auto")
		if err != nil {
			return "", "", err
		}
	}
	monero, err := memoryAlternative(document.root, "monero.mem_limit", "auto")
	if err != nil {
		return "", "", err
	}
	if monero == "" || monero == "auto" {
		monero = "6g"
	}
	return tari, monero, nil
}

func TariMemoryLimit(ramMB, hugeMB string) (string, error) {
	ram, err := memoryFact(ramMB)
	if err != nil {
		return "", err
	}
	huge, err := memoryFact(hugeMB)
	if err != nil {
		return "", err
	}
	if ram <= 0 {
		ram = 16384
	}
	if huge < 0 {
		huge = 0
	}
	available := ram - huge
	if available < 2048 {
		available = 2048
	}
	reserve := available / 4
	if reserve < 2048 {
		reserve = 2048
	}
	limit := available - reserve
	if limit < 2048 {
		limit = 2048
	}
	return strconv.FormatInt(limit, 10) + "m", nil
}

func memoryAlternative(root node, path, fallback string) (string, error) {
	value, err := getStringPath(root, path)
	if err != nil || value.object != nil || value.array != nil {
		return "", ErrUnsupportedMemory
	}
	if isNull(value) || value.value == false {
		return fallback, nil
	}
	if text, ok := value.value.(string); ok {
		for _, current := range text {
			if current <= 0x1f || current >= 0x7f && current <= 0x9f {
				return "", ErrUnsupportedMemory
			}
		}
		return text, nil
	}
	rendered, err := rawJQ(value)
	if err != nil || len(rendered) == 0 || rendered[len(rendered)-1] != '\n' {
		return "", ErrUnsupportedMemory
	}
	return string(rendered[:len(rendered)-1]), nil
}

func memoryFact(value string) (int64, error) {
	if value == "" {
		return 0, nil
	}
	digits := value
	if digits[0] == '-' {
		digits = digits[1:]
		if digits == "" || digits == "0" {
			return 0, ErrUnsupportedMemory
		}
	}
	if digits == "0" {
		return 0, nil
	}
	if digits[0] < '1' || digits[0] > '9' {
		return 0, ErrUnsupportedMemory
	}
	for _, current := range digits[1:] {
		if current < '0' || current > '9' {
			return 0, ErrUnsupportedMemory
		}
	}
	parsed, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, ErrUnsupportedMemory
	}
	return parsed, nil
}
