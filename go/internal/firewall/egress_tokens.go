package firewall

import (
	"sort"
	"strings"
)

type egressToken struct {
	Text   string
	Quoted bool
}

func egressTokenise(line string) ([]egressToken, bool, error) {
	if strings.IndexByte(line, 0) >= 0 {
		return nil, false, ErrUnsupportedInput
	}
	tokens := make([]egressToken, 0)
	var token strings.Builder
	have := false
	quoted := false
	for index := 0; index < len(line); {
		char := line[index]
		if char >= 0x80 {
			return nil, false, ErrUnsupportedInput
		}
		if isShellSpace(char) {
			if have {
				tokens = append(tokens, egressToken{Text: token.String(), Quoted: quoted})
				token.Reset()
				have = false
				quoted = false
			}
			index++
			continue
		}
		if char != '"' {
			token.WriteByte(char)
			have = true
			index++
			continue
		}
		index++
		have = true
		quoted = true
		closed := false
		for index < len(line) {
			char = line[index]
			if char == '\\' {
				index++
				if index == len(line) {
					return tokens, false, nil
				}
				char = line[index]
			} else if char == '"' {
				closed = true
				index++
				break
			}
			if char == '\n' {
				return nil, false, ErrUnsupportedInput
			}
			token.WriteByte(char)
			index++
		}
		if !closed {
			return tokens, false, nil
		}
	}
	if have {
		tokens = append(tokens, egressToken{Text: token.String(), Quoted: quoted})
	}
	return tokens, true, nil
}

func egressCanonical(line string) (string, bool, error) {
	tokens, ok, err := egressTokenise(line)
	if err != nil || !ok || len(tokens) == 0 || len(tokens)%2 != 0 {
		return "", false, err
	}
	pairs := make([]string, 0, len(tokens)/2)
	for index := 0; index < len(tokens); index += 2 {
		key := tokens[index]
		if key.Quoted || !strings.HasPrefix(key.Text, "-") {
			return "", false, nil
		}
		value := tokens[index+1].Text
		if key.Text == "-s" {
			value = strings.TrimSuffix(value, "/32")
		}
		if key.Text == "--ctstate" {
			states := strings.Split(value, ",")
			sort.Strings(states)
			value = strings.Join(states, ",")
		}
		pairs = append(pairs, "b:"+key.Text+"="+value)
	}
	sort.Strings(pairs)
	return strings.Join(pairs, "\n"), true, nil
}

func egressSyncAccept(line, ip string) (bool, error) {
	if strings.IndexByte(ip, 0) >= 0 || strings.Contains(ip, "\n") {
		return false, ErrUnsupportedInput
	}
	tokens, ok, err := egressTokenise(line)
	if err != nil || !ok || len(tokens)%2 != 0 {
		return false, err
	}
	chain := false
	module := false
	target := false
	source := ""
	comment := ""
	for index := 0; index < len(tokens); index += 2 {
		key, value := tokens[index], tokens[index+1]
		if key.Quoted {
			return false, nil
		}
		switch key.Text {
		case "-A":
			if chain || value.Quoted || value.Text != "DOCKER-USER" {
				return false, nil
			}
			chain = true
		case "-s":
			if source != "" || value.Quoted {
				return false, nil
			}
			source = "b:" + value.Text
		case "-m":
			if module || value.Quoted || value.Text != "comment" {
				return false, nil
			}
			module = true
		case "--comment":
			if comment != "" {
				return false, nil
			}
			comment = value.Text
		case "-j":
			if target || value.Quoted || value.Text != "ACCEPT" {
				return false, nil
			}
			target = true
		default:
			return false, nil
		}
	}
	return chain && module && comment == EgressTag && target &&
		(source == "b:"+ip || source == "b:"+ip+"/32"), nil
}

func isShellSpace(char byte) bool {
	switch char {
	case ' ', '\t', '\n', '\v', '\f', '\r':
		return true
	default:
		return false
	}
}
