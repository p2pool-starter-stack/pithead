package web

import (
	"encoding/json"
	"testing"
)

func TestOverviewCompletionRefusesUnknownFieldsAndOperations(t *testing.T) {
	for _, input := range []map[string]json.RawMessage{
		{"control_enabled": json.RawMessage(`{"operation":"visible_update","args":[null,null]}`)},
		{"update": json.RawMessage(`{"operation":"_egress_badge","args":[{}]}`)},
		{"badges": json.RawMessage(`{"operation":"visible_update","args":[null,null]}`)},
	} {
		if _, err := completeOverview(map[string]json.RawMessage{}, input); err == nil {
			t.Fatalf("unsafe overview accepted: %s", input)
		}
	}
}

func TestOverviewCompletionSetsOnlyNativeResultFields(t *testing.T) {
	state, err := completeOverview(map[string]json.RawMessage{"control_enabled": json.RawMessage(`false`)}, map[string]json.RawMessage{
		"raffle_eligible": json.RawMessage(`{"operation":"build_raffle_eligibility","args":[{"xvb_enabled":false}]}`),
		"update":          json.RawMessage(`{"operation":"visible_update","args":[null,null]}`),
	})
	if err != nil {
		t.Fatal(err)
	}
	if string(state["control_enabled"]) != "false" || string(state["update"]) != "null" || len(state) != 3 {
		t.Fatalf("completed overview = %s", state)
	}
}
