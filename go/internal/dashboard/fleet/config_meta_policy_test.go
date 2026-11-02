package fleet

import (
	"encoding/json"
	"reflect"
	"strings"
	"testing"
)

func TestConfigMetaPolicyAcceptsExistingRigforgeRules(t *testing.T) {
	value, err := Build(configMetaPolicyRequest(`{
		"revision":{"kind":"string","length":6,"value":"rev-1\n"},
		"changed_at":{"kind":"string","length":21,"value":"٢٠٢٦-٠٨-٢٣T١٤:٣٠:٤٥Z\n"},
		"source":{"kind":"string","length":7,"value":"control"},
		"last_change_id":{"kind":"string","length":4,"value":"c_1."}
	}`))
	want := configMetaPolicy{Revision: true, ChangedAt: true, Source: true, LastChangeID: true}
	if err != nil || !reflect.DeepEqual(value, want) {
		t.Fatalf("policy=%#v err=%v", value, err)
	}
}

func TestConfigMetaPolicyRejectsInvalidAndOversizedFields(t *testing.T) {
	value, err := Build(configMetaPolicyRequest(`{
		"revision":{"kind":"string","length":8,"value":"bad/rev!"},
		"changed_at":{"kind":"string","length":20,"value":"2026-08-23 14:30:45Z"},
		"source":{"kind":"string","length":6,"value":"vendor"},
		"last_change_id":{"kind":"string","length":65}
	}`))
	want := configMetaPolicy{}
	if err != nil || !reflect.DeepEqual(value, want) {
		t.Fatalf("policy=%#v err=%v", value, err)
	}
}

func TestConfigMetaPolicyBoundsAndOtherTypes(t *testing.T) {
	revision := strings.Repeat("x", 64)
	value, err := Build(configMetaPolicyRequest(`{
		"revision":{"kind":"string","length":64,"value":"` + revision + `"},
		"changed_at":{"kind":"other"},
		"source":{"kind":"other"},
		"last_change_id":{"kind":"other"}
	}`))
	want := configMetaPolicy{Revision: true}
	if err != nil || !reflect.DeepEqual(value, want) {
		t.Fatalf("policy=%#v err=%v", value, err)
	}
	fourByte := strings.Repeat("😀", 64)
	value, err = Build(configMetaPolicyRequest(`{
		"revision":{"kind":"string","length":64,"value":"` + fourByte + `"},
		"changed_at":{"kind":"other"},
		"source":{"kind":"other"},
		"last_change_id":{"kind":"other"}
	}`))
	if err != nil || !reflect.DeepEqual(value, configMetaPolicy{}) {
		t.Fatalf("unicode policy=%#v err=%v", value, err)
	}
}

func TestConfigMetaPolicyMatchesPython311UnicodeDigits(t *testing.T) {
	for _, digit := range []rune{0x10D40, 0x116D0, 0x11BF0, 0x11DE0, 0x11F50, 0x16130, 0x16D70, 0x1CCF0, 0x1E4F0, 0x1E5F1} {
		stamp := string(digit) + "026-08-23T14:30:45Z"
		value, err := Build(configMetaPolicyRequest(`{
			"revision":{"kind":"other"},
			"changed_at":{"kind":"string","length":20,"value":"` + stamp + `"},
			"source":{"kind":"other"},
			"last_change_id":{"kind":"other"}
		}`))
		if err != nil || !reflect.DeepEqual(value, configMetaPolicy{}) {
			t.Fatalf("digit %U policy=%#v err=%v", digit, value, err)
		}
	}
	stamp := string(rune(0x1E950)) + "026-08-23T14:30:45Z"
	value, err := Build(configMetaPolicyRequest(`{
		"revision":{"kind":"other"},
		"changed_at":{"kind":"string","length":20,"value":"` + stamp + `"},
		"source":{"kind":"other"},
		"last_change_id":{"kind":"other"}
	}`))
	want := configMetaPolicy{ChangedAt: true}
	if err != nil || !reflect.DeepEqual(value, want) {
		t.Fatalf("Unicode 14 policy=%#v err=%v", value, err)
	}
}

func TestConfigMetaPolicyRejectsMalformedProjection(t *testing.T) {
	validOther := `{"kind":"other"}`
	cases := []string{
		`null`,
		`[]`,
		`{}`,
		`{"revision":` + validOther + `,"changed_at":` + validOther + `,"source":` + validOther + `}`,
		`{"revision":` + validOther + `,"changed_at":` + validOther + `,"source":` + validOther + `,"last_change_id":` + validOther + `,"extra":` + validOther + `}`,
	}
	badFields := []string{
		`null`,
		`{}`,
		`{"kind":null}`,
		`{"kind":"bad"}`,
		`{"kind":"other","value":"x"}`,
		`{"kind":"string"}`,
		`{"kind":"string","length":null}`,
		`{"kind":"string","length":true}`,
		`{"kind":"string","length":1.0}`,
		`{"kind":"string","length":-1}`,
		`{"kind":"string","length":66}`,
		`{"kind":"string","length":1}`,
		`{"kind":"string","length":1,"value":null}`,
		`{"kind":"string","length":1,"value":1}`,
		`{"kind":"string","length":1,"value":"xx"}`,
		`{"kind":"string","length":65,"value":"x"}`,
		`{"kind":"string","length":65,"extra":true}`,
		`{"kind":"string","length":1,"value":"x","extra":true}`,
	}
	for _, bad := range badFields {
		cases = append(cases, `{"revision":`+bad+`,"changed_at":`+validOther+`,"source":`+validOther+`,"last_change_id":`+validOther+`}`)
	}
	for _, input := range cases {
		if _, err := Build(configMetaPolicyRequest(input)); err == nil {
			t.Fatalf("accepted %s", input)
		}
	}
	if _, err := Build(Request{Operation: "config_meta_policy"}); err == nil {
		t.Fatal("accepted missing projection")
	}
	request := configMetaPolicyRequest(cases[3])
	request.Args = append(request.Args, json.RawMessage(`{}`))
	if _, err := Build(request); err == nil {
		t.Fatal("accepted extra projection")
	}
}

func configMetaPolicyRequest(value string) Request {
	return Request{Operation: "config_meta_policy", Args: []json.RawMessage{json.RawMessage(value)}}
}
