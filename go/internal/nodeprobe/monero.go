package nodeprobe

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"unicode/utf8"
)

var ErrUnsupportedProbeInput = errors.New("unsupported node probe input")

type MoneroRPC struct {
	Host        string
	Port        string
	User        string
	Password    string
	MaxFileSize string
}

func (rpc MoneroRPC) Check() (string, error) {
	values := []string{rpc.Host, rpc.Port, rpc.User, rpc.Password, rpc.MaxFileSize}
	for _, value := range values {
		if !utf8.ValidString(value) || strings.ContainsRune(value, 0) {
			return "", ErrUnsupportedProbeInput
		}
	}
	rpc.User = strings.TrimRight(rpc.User, "\n")
	rpc.Password = strings.TrimRight(rpc.Password, "\n")
	cap := rpc.MaxFileSize
	if cap == "" {
		cap = "1048576"
	}
	timeout, reason, err := timeoutTool()
	if err != nil || reason != "" {
		return reason, err
	}
	host := rpc.Host
	if !(strings.HasPrefix(host, "[") && strings.HasSuffix(host, "]")) && strings.Contains(host, ":") {
		host = "[" + host + "]"
	}
	args := []string{"6", "curl", "-sS", "--noproxy", "*", "--max-time", "5", "--max-filesize", cap}
	input := ""
	if rpc.User != "" {
		args = append(args, "--digest")
		input = "user = " + quoteJQString(rpc.User+":"+rpc.Password)
	}
	args = append(args, "--config", "-", "-w", `\n%{http_code}`, "http://"+host+":"+rpc.Port+"/get_info")
	command := exec.Command(timeout, args...)
	command.Stdin = strings.NewReader(input)
	output, runErr := command.Output()
	if bytes.IndexByte(output, 0) >= 0 {
		return "", ErrUnsupportedProbeInput
	}
	if runErr != nil {
		var status *exec.ExitError
		if !errors.As(runErr, &status) {
			return "", ErrUnsupportedProbeInput
		}
		return transportReason(status.ExitCode()), nil
	}
	return ClassifyMoneroRPC(string(output), 0)
}

func timeoutTool() (string, string, error) {
	path, err := exec.LookPath("timeout")
	if err == nil {
		return path, "", nil
	}
	if errors.Is(err, exec.ErrDot) {
		return "", "", ErrUnsupportedProbeInput
	}
	for _, dir := range filepath.SplitList(os.Getenv("PATH")) {
		if dir == "" {
			dir = "."
		}
		if _, statErr := os.Lstat(filepath.Join(dir, "timeout")); statErr == nil {
			return "", "", ErrUnsupportedProbeInput
		} else if !os.IsNotExist(statErr) {
			return "", "", ErrUnsupportedProbeInput
		}
	}
	return "", "missing-tool", nil
}

func ClassifyMoneroRPC(output string, exitCode int) (string, error) {
	if strings.ContainsRune(output, 0) {
		return "", ErrUnsupportedProbeInput
	}
	if exitCode != 0 {
		return transportReason(exitCode), nil
	}
	output = strings.TrimRight(output, "\n")
	body, code := output, output
	if split := strings.LastIndexByte(output, '\n'); split >= 0 {
		body, code = output[:split], output[split+1:]
	}
	switch code {
	case "401", "403":
		return "auth", nil
	case "200":
	default:
		return "protocol", nil
	}
	return classifyMoneroBody(body)
}

func transportReason(exitCode int) string {
	switch exitCode {
	case 7:
		return "refused"
	case 28, 124:
		return "timeout"
	case 63:
		return "unusable"
	case 127:
		return "missing-tool"
	default:
		return "unknown"
	}
}

func classifyMoneroBody(body string) (string, error) {
	if strings.TrimSpace(body) == "" {
		return "protocol", nil
	}
	if !utf8.ValidString(body) || strings.Contains(body, `\u`) {
		return "", ErrUnsupportedProbeInput
	}
	decoder := json.NewDecoder(strings.NewReader(body))
	decoder.UseNumber()
	var decoded any
	if err := decoder.Decode(&decoded); err != nil {
		return "", ErrUnsupportedProbeInput
	}
	var extra any
	if err := decoder.Decode(&extra); !errors.Is(err, io.EOF) {
		return "", ErrUnsupportedProbeInput
	}
	object, ok := decoded.(map[string]any)
	if !ok || object["status"] != "OK" {
		return "protocol", nil
	}
	nettype, ok := object["nettype"].(string)
	if !ok || nettype != "mainnet" && nettype != "testnet" && nettype != "stagenet" {
		return "protocol", nil
	}
	for _, key := range []string{"height", "target_height"} {
		number, ok := object[key].(json.Number)
		if !ok {
			return "protocol", nil
		}
		value := number.String()
		if strings.HasPrefix(value, "-") {
			if value == "-0" || !decimalDigits(strings.TrimPrefix(value, "-")) {
				return "", ErrUnsupportedProbeInput
			}
			return "protocol", nil
		}
		if !decimalDigits(value) {
			return "", ErrUnsupportedProbeInput
		}
		integer, err := strconv.ParseUint(value, 10, 64)
		if err != nil || integer > 9007199254740991 {
			return "", ErrUnsupportedProbeInput
		}
	}
	return "ok", nil
}

func decimalDigits(value string) bool {
	if value == "" {
		return false
	}
	for _, digit := range []byte(value) {
		if digit < '0' || digit > '9' {
			return false
		}
	}
	return true
}

func quoteJQString(value string) string {
	const hex = "0123456789abcdef"
	var quoted strings.Builder
	quoted.Grow(len(value) + 2)
	quoted.WriteByte('"')
	for _, r := range value {
		switch r {
		case '"', '\\':
			quoted.WriteByte('\\')
			quoted.WriteRune(r)
		case '\b':
			quoted.WriteString(`\b`)
		case '\f':
			quoted.WriteString(`\f`)
		case '\n':
			quoted.WriteString(`\n`)
		case '\r':
			quoted.WriteString(`\r`)
		case '\t':
			quoted.WriteString(`\t`)
		default:
			if r < 0x20 || r == 0x7f {
				quoted.WriteString(`\u00`)
				quoted.WriteByte(hex[byte(r)>>4])
				quoted.WriteByte(hex[byte(r)&0xf])
			} else {
				quoted.WriteRune(r)
			}
		}
	}
	quoted.WriteByte('"')
	return quoted.String()
}
