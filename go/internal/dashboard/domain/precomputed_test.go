package domain

import (
	"reflect"
	"testing"
)

func TestBuildUsesPrecomputedHistoryAverages(t *testing.T) {
	input := baseInput()
	input.History = []map[string]any{{"timestamp": "invalid"}}
	input.Averages = &Averages{
		P2Pool1H: 11, P2Pool24H: 22, P2Pool30D: 33,
		XVBRouted1H: 44, XVBRouted24H: 55,
	}
	got, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]any{
		"p2pool_1h": PythonFloat(11), "p2pool_24h": PythonFloat(22),
		"p2pool_30d": PythonFloat(33), "xvb_routed_1h": PythonFloat(44),
		"xvb_routed_24h": PythonFloat(55),
	}
	for key, value := range want {
		if !reflect.DeepEqual(got[key], value) {
			t.Errorf("%s = %#v, want %#v", key, got[key], value)
		}
	}
}
