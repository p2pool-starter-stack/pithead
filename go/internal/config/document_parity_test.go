//go:build parity

package config

import (
	"encoding/json"
	"fmt"
	"strconv"
	"strings"
	"testing"
)

func TestDocumentParityDuplicates(t *testing.T) {
	for name, raw := range map[string]string{
		"root":               `{"a":1,"a":2}`,
		"null":               `{"a":null,"a":false}`,
		"escaped-key":        `{"a":{},"\u0061":{}}`,
		"nested":             `{"dashboard":{"auth":{"password":"first","password":"last"}}}`,
		"array":              `{"workers":{"list":[{"token":1,"token":2}]}}`,
		"first-child":        `{"a":{"x":1,"x":2},"a":{"y":1,"y":2}}`,
		"duplicate-value":    `{"a":1,"a":{"x":1,"x":2}}`,
		"before-placeholder": `{"secret":"YOUR_hidden","later":{"x":1,"x":2}}`,
		"invalid-object":     `{"a":1,"a":2,}`,
		"invalid-array":      `[{"a":1,"a":2},]`,
		"invalid-tail":       `{"a":1,"a":2} trailing`,
		"request-actor":      `{"actor":{"a":1,"a":2},"config":{}}`,
	} {
		for _, request := range []bool{false, true} {
			t.Run(name+"/request-"+strconv.FormatBool(request), func(t *testing.T) {
				compareDocument(t, []byte(raw), request, false)
			})
		}
	}
}

func TestDocumentParityPaths(t *testing.T) {
	for index, key := range []string{"", "dot.key", "array[3]", "quote\"key", "slash\\key", "\n\r\t\b\f\x00\x1b\x7f", "café", "雪", "😀", "<>&", "\u2028\u2029", "\\\""} {
		encoded, err := json.Marshal(key)
		if err != nil {
			t.Fatal(err)
		}
		for name, raw := range map[string]string{
			"duplicate": fmt.Sprintf(`{%s:1,%s:2}`, encoded, encoded),
			"nested":    fmt.Sprintf(`{%s:[{"secret":"YOUR_hidden"}]}`, encoded),
		} {
			t.Run(strconv.Itoa(index)+"/"+name, func(t *testing.T) {
				compareDocument(t, []byte(raw), false, false)
			})
		}
	}
}

func TestDocumentParityPlaceholders(t *testing.T) {
	for _, value := range []string{"PASTE_hidden", "your_hidden", "pAsTe_hidden", "YoUr_hidden", "PAſTE_hidden", "PAﬅE_hidden", "PAﬆE_hidden", "YOUR_", "PASTE_", "prefix_YOUR_", " YOUR_hidden", "YOUR", "PASTE", "", "opaque"} {
		encoded, _ := json.Marshal(value)
		for _, request := range []bool{false, true} {
			t.Run(value+"/request-"+strconv.FormatBool(request), func(t *testing.T) {
				compareDocument(t, []byte(`{"actor":"YOUR_actor","config":{"workers":[{"token":`+string(encoded)+`}]}}`), request, false)
			})
		}
		if strings.HasPrefix(value, "PASTE") || strings.HasPrefix(value, "YOUR") {
			t.Run(value+"/root", func(t *testing.T) {
				compareDocument(t, encoded, false, false)
			})
		}
	}
}

func TestDocumentParityJSON(t *testing.T) {
	for index, raw := range []string{"", " ", "{", `{"a":`, "[]\n{}", "null", "true", "false", "123", "1e300", `"opaque"`, "[]", "{}", `{"label":"NaN Infinity"}`, `{"config":null,"actor":"YOUR_actor"}`, `{"config":["YOUR_hidden"]}`, `{"actor":"YOUR_actor"}`, `{"YOUR_key":"opaque"}`, `{"a":{"x":1},"b":{"x":2}}`, "\xef\xbb\xbf{}", `{"a":"bad\q"}`} {
		for _, request := range []bool{false, true} {
			t.Run(strconv.Itoa(index)+"/request-"+strconv.FormatBool(request), func(t *testing.T) {
				compareDocument(t, []byte(raw), request, false)
			})
		}
	}
	t.Run("missing", func(t *testing.T) { compareDocument(t, nil, false, false) })
}

func TestDocumentParityCompatibility(t *testing.T) {
	for name, raw := range map[string][]byte{
		"invalid-utf8":      []byte("{\"a\":\"\xff\"}"),
		"lone-surrogate":    []byte(`{"\ud800":"YOUR_hidden"}`),
		"surrogate-pair":    []byte(`{"\ud83d\ude00":"YOUR_hidden"}`),
		"nan":               []byte(`{"a":NaN}`),
		"infinity":          []byte(`{"a":Infinity}`),
		"negative-infinity": []byte(`{"a":-Infinity}`),
		"large-integer":     []byte(`{"a":` + strings.Repeat("9", 4301) + `}`),
		"deep":              []byte(strings.Repeat("[", 1200) + "0" + strings.Repeat("]", 1200)),
	} {
		t.Run(name, func(t *testing.T) { compareDocument(t, raw, false, true) })
	}
}
