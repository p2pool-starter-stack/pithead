package doctor

import (
	"bytes"
	"encoding/json"
	"io"
	"unicode/utf8"
)

type report struct {
	Version string  `json:"version"`
	Exit    int     `json:"exit"`
	Summary summary `json:"summary"`
	Checks  []check `json:"checks"`
}

type summary struct {
	OK   int `json:"ok"`
	Warn int `json:"warn"`
	Fail int `json:"fail"`
	Info int `json:"info"`
}

type check struct {
	ID      *string `json:"id"`
	Status  string  `json:"status"`
	Message *string `json:"message"`
}

func WriteJSON(out io.Writer, version string, exit int, rows []byte) error {
	document := report{Version: jqString([]byte(version)), Exit: exit, Checks: []check{}}
	for _, line := range bytes.Split(rows, []byte{'\n'}) {
		if len(line) == 0 {
			continue
		}
		fields := bytes.Split(line, []byte{'\t'})
		entry := check{Status: jqString(fields[0])}
		if len(fields) > 1 {
			message := jqString(fields[1])
			entry.Message = &message
		}
		if len(fields) > 2 {
			id := jqString(fields[2])
			entry.ID = &id
		}
		switch entry.Status {
		case "ok":
			document.Summary.OK++
		case "warn":
			document.Summary.Warn++
		case "fail":
			document.Summary.Fail++
		case "info":
			document.Summary.Info++
		}
		document.Checks = append(document.Checks, entry)
	}

	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetEscapeHTML(false)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(document); err != nil {
		return err
	}
	_, err := io.Copy(out, bytes.NewReader(jqEncoding(encoded.Bytes())))
	return err
}

func jqString(value []byte) string {
	result := make([]byte, 0, len(value))
	for index := 0; index < len(value); {
		first := value[index]
		if first < utf8.RuneSelf {
			result = append(result, first)
			index++
			continue
		}
		width := 0
		switch {
		case first >= 0xc2 && first <= 0xdf:
			width = 2
		case first >= 0xe0 && first <= 0xef:
			width = 3
		case first >= 0xf0 && first <= 0xf4:
			width = 4
		}
		if width == 0 {
			result = utf8.AppendRune(result, utf8.RuneError)
			index++
			continue
		}
		available := 1
		for available < width && index+available < len(value) && value[index+available]&0xc0 == 0x80 {
			available++
		}
		if available == width {
			runeValue, size := utf8.DecodeRune(value[index : index+width])
			if runeValue != utf8.RuneError || size != 1 {
				result = append(result, value[index:index+width]...)
				index += width
				continue
			}
		}
		result = utf8.AppendRune(result, utf8.RuneError)
		index += available
	}
	return string(result)
}

func jqEncoding(encoded []byte) []byte {
	result := make([]byte, 0, len(encoded))
	for index := 0; index < len(encoded); {
		if encoded[index] == 0x7f {
			result = append(result, `\u007f`...)
			index++
			continue
		}
		if encoded[index] != '\\' {
			result = append(result, encoded[index])
			index++
			continue
		}
		end := index
		for end < len(encoded) && encoded[end] == '\\' {
			end++
		}
		count := end - index
		if count%2 == 1 && end+5 <= len(encoded) &&
			(bytes.Equal(encoded[end:end+5], []byte("u2028")) || bytes.Equal(encoded[end:end+5], []byte("u2029"))) {
			result = append(result, encoded[index:end-1]...)
			if encoded[end+4] == '8' {
				result = append(result, 0xe2, 0x80, 0xa8)
			} else {
				result = append(result, 0xe2, 0x80, 0xa9)
			}
			index = end + 5
			continue
		}
		result = append(result, encoded[index:end]...)
		index = end
	}
	return result
}
