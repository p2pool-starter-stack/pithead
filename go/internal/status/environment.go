package status

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
)

func (r *Runner) get(key string) string {
	return r.envValue(key, false)
}

func (r *Runner) getQuiet(key string) string {
	return r.envValue(key, true)
}

func (r *Runner) envValue(key string, quiet bool) string {
	data, err := os.ReadFile(r.path(r.EnvFile))
	if err != nil {
		return ""
	}
	for _, line := range strings.Split(shellValue(string(data)), "\n") {
		if strings.HasPrefix(line, key+"=") {
			value := decode(strings.TrimPrefix(line, key+"="))
			if strings.HasSuffix(key, "_DIR") && strings.ContainsAny(value, "\r\n") {
				if !quiet {
					fmt.Fprintf(r.Err, "%s[ERROR]%s Directory values in .env must not contain CR or LF.\n", r.red, r.reset)
				}
				return ""
			}
			return shellValue(value)
		}
	}
	return ""
}

func decode(value string) string {
	if len(value) < 2 || value[0] != '"' || value[len(value)-1] != '"' {
		return value
	}
	value = value[1 : len(value)-1]
	var decoded strings.Builder
	for i := 0; i < len(value); i++ {
		ch := value[i]
		if ch == '\\' && i+1 < len(value) {
			i++
			ch = value[i]
			switch ch {
			case 'n':
				ch = '\n'
			case 'r':
				ch = '\r'
			case 't':
				ch = '\t'
			}
		} else if ch == '$' && i+1 < len(value) && value[i+1] == '$' {
			i++
		}
		decoded.WriteByte(ch)
	}
	return decoded.String()
}

func echoEscapes(value string) string {
	var result strings.Builder
	for i := 0; i < len(value); i++ {
		if value[i] != '\\' || i+1 == len(value) {
			result.WriteByte(value[i])
			continue
		}
		i++
		switch value[i] {
		case 'c':
			return result.String()
		case 'a':
			result.WriteByte('\a')
		case 'b':
			result.WriteByte('\b')
		case 'e', 'E':
			result.WriteByte(27)
		case 'f':
			result.WriteByte('\f')
		case 'n':
			result.WriteByte('\n')
		case 'r':
			result.WriteByte('\r')
		case 't':
			result.WriteByte('\t')
		case 'v':
			result.WriteByte('\v')
		case '\\':
			result.WriteByte('\\')
		case '0', 'x', 'u', 'U':
			base, limit, start := 16, 2, i+1
			switch value[i] {
			case '0':
				base, limit = 8, 3
			case 'u':
				limit = 4
			case 'U':
				limit = 8
			}
			end := start
			for end < len(value) && end-start < limit {
				if _, err := strconv.ParseUint(value[end:end+1], base, 8); err != nil {
					break
				}
				end++
			}
			if end == start {
				if value[i] == '0' {
					result.WriteByte(0)
				} else {
					result.WriteByte('\\')
					result.WriteByte(value[i])
				}
				continue
			}
			n, _ := strconv.ParseUint(value[start:end], base, 32)
			if limit > 3 {
				writeBashUnicode(&result, n, value[i], value[start:end])
			} else {
				result.WriteByte(byte(n))
			}
			i = end - 1
		default:
			result.WriteByte('\\')
			result.WriteByte(value[i])
		}
	}
	return result.String()
}

func writeBashUnicode(result *strings.Builder, value uint64, prefix byte, digits string) {
	if value >= 1<<31 {
		return
	}
	if value > 0x7f && !bashUTF8Locale() {
		result.WriteByte('\\')
		result.WriteByte(prefix)
		result.WriteString(digits)
		return
	}
	for _, part := range bashUTF8Bytes(uint32(value)) {
		result.WriteByte(part)
	}
}

func bashUTF8Locale() bool {
	locale := effectiveLocale()
	return locale != "" && locale != "C" && locale != "POSIX"
}

func LocaleSupported() bool {
	locale := effectiveLocale()
	if locale == "" || locale == "C" || locale == "POSIX" {
		return true
	}
	command := exec.Command("locale", "charmap")
	var stderr bytes.Buffer
	command.Stderr = &stderr
	output, err := command.Output()
	if err != nil || stderr.Len() != 0 {
		return false
	}
	charmap := strings.NewReplacer("-", "", "_", "").Replace(strings.TrimSpace(string(output)))
	return strings.EqualFold(charmap, "UTF8")
}

func effectiveLocale() string {
	for _, key := range []string{"LC_ALL", "LC_CTYPE", "LANG"} {
		if locale := os.Getenv(key); locale != "" {
			return locale
		}
	}
	return ""
}

func bashUTF8Bytes(value uint32) []byte {
	size, prefix := 1, byte(0)
	switch {
	case value <= 0x7f:
		return []byte{byte(value)}
	case value <= 0x7ff:
		size, prefix = 2, 0xc0
	case value <= 0xffff:
		size, prefix = 3, 0xe0
	case value <= 0x1fffff:
		size, prefix = 4, 0xf0
	case value <= 0x3ffffff:
		size, prefix = 5, 0xf8
	default:
		size, prefix = 6, 0xfc
	}
	encoded := make([]byte, size)
	for index := size - 1; index > 0; index-- {
		encoded[index] = 0x80 | byte(value&0x3f)
		value >>= 6
	}
	encoded[0] = prefix | byte(value)
	return encoded
}
