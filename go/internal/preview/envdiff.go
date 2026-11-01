package preview

import (
	"bytes"
	"sort"
)

func EnvChangedKeys(first, second []byte) ([]byte, bool) {
	if bytes.IndexByte(first, 0) >= 0 || bytes.IndexByte(second, 0) >= 0 {
		return nil, false
	}
	a, b := lines(first), lines(second)
	sort.Slice(a, func(i, j int) bool { return bytes.Compare(a[i], a[j]) < 0 })
	sort.Slice(b, func(i, j int) bool { return bytes.Compare(b[i], b[j]) < 0 })
	keys := make([][]byte, 0)
	for i, j := 0, 0; i < len(a) || j < len(b); {
		if i < len(a) && j < len(b) && bytes.Equal(a[i], b[j]) {
			i++
			j++
			continue
		}
		if j == len(b) || (i < len(a) && bytes.Compare(a[i], b[j]) < 0) {
			keys = append(keys, envKey(a[i]))
			i++
		} else {
			keys = append(keys, envKey(b[j]))
			j++
		}
	}
	sort.Slice(keys, func(i, j int) bool { return bytes.Compare(keys[i], keys[j]) < 0 })
	var output bytes.Buffer
	for i, key := range keys {
		if i > 0 && bytes.Equal(key, keys[i-1]) {
			continue
		}
		output.Write(key)
		output.WriteByte('\n')
	}
	return output.Bytes(), true
}

func lines(raw []byte) [][]byte {
	if len(raw) == 0 {
		return nil
	}
	parts := bytes.Split(raw, []byte{'\n'})
	if len(parts[len(parts)-1]) == 0 {
		parts = parts[:len(parts)-1]
	}
	return parts
}

func envKey(line []byte) []byte {
	line = bytes.TrimLeft(line, " \t\r\v\f")
	if index := bytes.IndexByte(line, '='); index >= 0 {
		line = line[:index]
	}
	return append([]byte(nil), line...)
}
