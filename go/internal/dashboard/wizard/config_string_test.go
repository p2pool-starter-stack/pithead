package wizard

import (
	"encoding/json"
	"testing"
)

func TestConfigStringWirePreservesSurrogateBytesInKeysAndValues(t *testing.T) {
	surrogate := string([]byte{0xed, 0xa0, 0x80})
	value := opDict(opField(surrogate, opString(surrogate)))
	raw, err := json.Marshal(value)
	if err != nil {
		t.Fatal(err)
	}
	var decoded ConfigValue
	if err := json.Unmarshal(raw, &decoded); err != nil {
		t.Fatal(err)
	}
	if len(decoded.Fields) != 1 || decoded.Fields[0].Key != surrogate || decoded.Fields[0].Value.Text != surrogate {
		t.Fatalf("lost surrogate bytes: %x", raw)
	}
	if !decoded.Equal(value) {
		t.Fatal("round trip changed equality")
	}
	prepared, changes, err := PrepareConfig(value, opDict(opField("known", opString(""))), opDict(), false)
	if err != nil || len(prepared.Fields) != 0 || len(changes) != 1 || changes[0] != surrogate+" removed" {
		t.Fatal("unknown key summary changed")
	}
	raw, err = json.Marshal(configStrings(changes))
	if err != nil || json.Unmarshal(raw, &decoded) != nil || decoded.Items[0].Text != changes[0] {
		t.Fatal("change summary lost surrogate bytes")
	}
}

func TestConfigStringRejectsMalformedByteTag(t *testing.T) {
	for _, raw := range []string{`["str-bytes","!"]`, `["str-bytes"]`, `["str-bytes",null]`, `["dict",[[["bad","eA=="],["null",null]]]]`} {
		var value ConfigValue
		if json.Unmarshal([]byte(raw), &value) == nil {
			t.Fatalf("accepted malformed string tag %s", raw)
		}
	}
}
