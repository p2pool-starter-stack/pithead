package host

import (
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
)

var ErrUnsupportedIPInput = errors.New("unsupported public IP input")

func PublicIP(value string) (bool, error) {
	if strings.ContainsRune(value, 0) {
		return false, ErrUnsupportedIPInput
	}
	if strings.Contains(value, ":") {
		hextet := strings.SplitN(value, ":", 2)[0]
		if hextet == "" {
			return false, nil
		}
		for _, ch := range hextet {
			if !((ch >= '0' && ch <= '9') || (ch >= 'a' && ch <= 'f') || (ch >= 'A' && ch <= 'F')) {
				return false, nil
			}
		}
		first, err := strconv.ParseUint(hextet, 16, 64)
		if err != nil {
			return false, ErrUnsupportedIPInput
		}
		return first >= 0x2000 && first <= 0x3fff, nil
	}
	if !strings.Contains(value, ".") {
		return false, nil
	}
	parts := strings.Split(value, ".")
	if len(parts) != 4 {
		return false, nil
	}
	numbers := make([]int, 4)
	for index, part := range parts {
		if len(part) < 1 || len(part) > 3 {
			return false, nil
		}
		for _, ch := range part {
			if ch < '0' || ch > '9' {
				return false, nil
			}
		}
		number, _ := strconv.Atoi(part)
		if number > 255 {
			return false, nil
		}
		numbers[index] = number
	}
	switch parts[0] {
	case "0", "10", "127":
		return false, nil
	case "169":
		if parts[1] == "254" {
			return false, nil
		}
	case "172":
		if numbers[1] >= 16 && numbers[1] <= 31 {
			return false, nil
		}
	case "192":
		if parts[1] == "168" {
			return false, nil
		}
	case "100":
		if numbers[1] >= 64 && numbers[1] <= 127 {
			return false, nil
		}
	}
	return true, nil
}

func PublicIPs() (string, error) {
	for _, part := range filepath.SplitList(os.Getenv("PATH")) {
		if part == "" || !filepath.IsAbs(part) {
			return "", ErrUnsupportedIPInput
		}
	}
	path, err := exec.LookPath("ip")
	if err != nil {
		if errors.Is(err, exec.ErrDot) {
			return "", ErrUnsupportedIPInput
		}
		return "", nil
	}
	command := exec.Command(path, "-o", "addr", "show")
	output, runErr := command.Output()
	if runErr != nil {
		var exitErr *exec.ExitError
		if !errors.As(runErr, &exitErr) {
			return "", ErrUnsupportedIPInput
		}
	}
	text := string(output)
	if strings.IndexByte(text, 0) >= 0 {
		return "", ErrUnsupportedIPInput
	}
	lastNewline := strings.LastIndexByte(text, '\n')
	if lastNewline < 0 {
		return "", nil
	}
	var public strings.Builder
	for _, line := range strings.Split(text[:lastNewline], "\n") {
		fields := strings.FieldsFunc(line, func(ch rune) bool { return ch == ' ' || ch == '\t' })
		if len(fields) < 4 || (fields[2] != "inet" && fields[2] != "inet6") {
			continue
		}
		address := strings.SplitN(fields[3], "/", 2)[0]
		isPublic, classifyErr := PublicIP(address)
		if classifyErr != nil {
			return "", classifyErr
		}
		if isPublic {
			public.WriteString(address)
			public.WriteByte('\n')
		}
	}
	return public.String(), nil
}
