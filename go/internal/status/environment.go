package status

import (
	"fmt"
	"os"
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
				result.WriteRune(rune(n))
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
