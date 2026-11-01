package charts

import "testing"

func TestBuildUsesPreparedChartRowsAndDuration(t *testing.T) {
	duration := 30 * 86400.0
	input := Input{
		History: []map[string]any{
			{"timestamp": 1000.0, "t": "a", "v_p2pool": 10.0},
			{"timestamp": 1030.0, "t": "b", "v_p2pool": 20.0},
		},
		Shares:           []map[string]any{{"ts": 1015.0}},
		Range:            "1h",
		Now:              1_000_000,
		PreparedDuration: &duration,
	}
	chart, err := Build(input)
	if err != nil {
		t.Fatal(err)
	}
	if points := chart["p2pool"].([]map[string]any); len(points) != 2 {
		t.Fatalf("prepared rows were filtered: %#v", points)
	}
	if shares := chart["shares"].([]map[string]any); len(shares) != 1 {
		t.Fatalf("prepared shares were filtered: %#v", shares)
	}
	if chart["tension"] != 0.4 {
		t.Fatalf("tension = %#v", chart["tension"])
	}
}

func TestBuildRejectsInvalidPreparedDuration(t *testing.T) {
	duration := -1.0
	if _, err := Build(Input{Now: 1, PreparedDuration: &duration}); err == nil {
		t.Fatal("accepted invalid prepared duration")
	}
}
