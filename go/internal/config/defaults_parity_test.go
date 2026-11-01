//go:build parity

package config

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

func TestDefaultsParityRender(t *testing.T) {
	for _, platform := range []string{"diy", "appliance", "other"} {
		for _, mode := range []string{"new", "legacy", "other", ""} {
			t.Run(platform+"/"+mode, func(t *testing.T) {
				compareDefaults(t, defaultsCase{operation: "defaults", platform: platform, mode: mode})
			})
		}
		t.Run(platform+"/install", func(t *testing.T) {
			compareDefaults(t, defaultsCase{operation: "install", platform: platform})
		})
	}
}

func defaultLeafPaths(current node, path string) []string {
	if current.object == nil {
		return []string{path}
	}
	var paths []string
	for _, entry := range current.object {
		next := entry.key
		if path != "" {
			next = path + "." + next
		}
		paths = append(paths, defaultLeafPaths(entry.value, next)...)
	}
	return paths
}

func TestDefaultsParityLeaves(t *testing.T) {
	table := defaultsTable(t)
	document, err := ParseDocument(table)
	if err != nil {
		t.Fatal(err)
	}
	values, _ := objectValue(document.root, "values")
	for _, platform := range []string{"diy", "appliance"} {
		for _, path := range defaultLeafPaths(values, "") {
			for _, mode := range []string{"new", "legacy"} {
				t.Run(platform+"/"+mode+"/"+path, func(t *testing.T) {
					compareDefaults(t, defaultsCase{operation: "default", platform: platform, mode: mode, path: "." + path, table: table})
				})
			}
			t.Run(platform+"/absent/"+path, func(t *testing.T) {
				compareDefaults(t, defaultsCase{operation: "get", platform: platform, path: path, table: table, document: []byte(`{}`)})
			})
		}
	}
}

func TestDefaultsParityValues(t *testing.T) {
	for _, platform := range []string{"diy", "appliance"} {
		for index, value := range []string{`null`, `false`, `true`, `0`, `-7`, `""`, `[]`, `[1,false,"value"]`, `{"b":2,"a":1}`, `"last\n\n"`, `"zero\u0000end"`, `"<>&\u007f\u2028\u2029é雪😀"`} {
			t.Run(platform+"/"+strconv.Itoa(index), func(t *testing.T) {
				compareDefaults(t, defaultsCase{operation: "get", platform: platform, path: ".dashboard.host", document: []byte(`{"dashboard":{"host":` + value + `}}`)})
			})
		}
	}
	for _, path := range []string{"", ".", "..leaf", "missing", "a.", ".p2pool", "p2pool", "dashboard.energy"} {
		t.Run("path/"+path, func(t *testing.T) {
			compareDefaults(t, defaultsCase{operation: "get", platform: "diy", path: path, document: []byte(`{"":{"leaf":"empty"},"a":{"":"tail"}}`)})
		})
	}
}

func TestDefaultsParityTables(t *testing.T) {
	for index, table := range []string{
		`{"values":{"a":{"z":1,"x":2},"tari":{"clearnet_initial_sync":false},"monero":{"clearnet_initial_sync":false}},"appliance":{"a":{"x":false,"b":"new"}},"materialize":["a"],"LEGACY_ABSENT":[{"path":"a.z","value":0}]}`,
		`{"values":{"a":null,"tari":{"clearnet_initial_sync":false},"monero":{"clearnet_initial_sync":false}},"appliance":{"a":{"x":2}},"materialize":["a","missing"],"LEGACY_ABSENT":[{"path":"a.x","value":false,"platform":false}]}`,
		`{"values":{"":{"leaf":"empty"},"a":{"":"tail"},"tari":{"clearnet_initial_sync":false},"monero":{"clearnet_initial_sync":false}},"appliance":{},"materialize":[".leaf","a."],"LEGACY_ABSENT":[]}`,
	} {
		for _, platform := range []string{"diy", "appliance"} {
			for _, operation := range []string{"defaults", "install"} {
				t.Run(strconv.Itoa(index)+"/"+platform+"/"+operation, func(t *testing.T) {
					compareDefaults(t, defaultsCase{operation: operation, mode: "legacy", platform: platform, table: []byte(table)})
				})
			}
		}
	}
	t.Run("override-retirement", func(t *testing.T) {
		var table map[string]any
		if err := json.Unmarshal(defaultsTable(t), &table); err != nil {
			t.Fatal(err)
		}
		for _, entry := range table["LEGACY_ABSENT"].([]any) {
			item := entry.(map[string]any)
			if item["path"] == "tari.mode" {
				item["value"] = "off"
			}
		}
		raw, _ := json.Marshal(table)
		compareDefaults(t, defaultsCase{operation: "get", path: "tari.mode", platform: "diy", table: raw, document: []byte(`{}`)})
	})
}

func TestDefaultsParityCompatibility(t *testing.T) {
	for name, raw := range map[string][]byte{
		"decimal": []byte(`{"dashboard":{"host":1.0}}`), "exponent": []byte(`{"dashboard":{"host":1e3}}`),
		"negative-zero": []byte(`{"dashboard":{"host":-0}}`), "large": []byte(`{"dashboard":{"host":9007199254740992}}`),
		"duplicate": []byte(`{"dashboard":{"host":"first","host":"last"}}`), "malformed": []byte(`{"dashboard":`),
		"surrogate": []byte(`{"dashboard":{"host":"\ud83d\ude00"}}`), "opaque": []byte("{\"dashboard\":{\"host\":\"\xff\"}}"),
		"multiple": []byte(`{} {}`), "missing-file": nil, "deep": []byte(strings.Repeat("[", 130) + "0" + strings.Repeat("]", 130)),
	} {
		t.Run(name, func(t *testing.T) {
			compareDefaults(t, defaultsCase{operation: "get", path: "dashboard.host", platform: "diy", document: raw, unsupported: true})
		})
	}
	for _, path := range []string{"missing", "p2pool.pool.child", "workers.list.0"} {
		t.Run("path/"+path, func(t *testing.T) {
			compareDefaults(t, defaultsCase{operation: "default", path: path, mode: "new", platform: "diy", unsupported: true})
		})
	}
	for index, table := range []string{`{}`, `{"values":null}`, `{"values":{},"appliance":{},"materialize":[],"LEGACY_ABSENT":[],"extra":1.0}`, `{"values":{},"values":{},"appliance":{},"materialize":[],"LEGACY_ABSENT":[]}`} {
		t.Run("table/"+strconv.Itoa(index), func(t *testing.T) {
			compareDefaults(t, defaultsCase{operation: "defaults", mode: "new", platform: "diy", table: []byte(table), unsupported: true})
		})
	}
}
