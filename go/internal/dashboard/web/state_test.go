package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestNativeStateSeriesAssembly(t *testing.T) {
	input := json.RawMessage(`{"state":{"chart":null,"share_stats":null,"unchanged":"value"},"chart":{},"series":{"share_stats":{"operation":"build_share_stats","args":[[{"ts":1.25,"accepted":3}],"all"],"now":0}}}`)
	state, err := buildState(input)
	if err != nil {
		t.Fatal(err)
	}
	if string(state["unchanged"]) != `"value"` || string(state["share_stats"]) != `[{"a":3,"e":0,"i":0,"r":0,"x":1250}]` {
		t.Fatalf("state = %s, %s", state["unchanged"], state["share_stats"])
	}
	if string(state["chart"]) == "null" {
		t.Fatal("chart was not computed")
	}
}

func TestMalformedStateSeriesUsesReference(t *testing.T) {
	for _, series := range []string{
		`{"unexpected":{"operation":"build_blocks","args":[[],"all"]}}`,
		`{"blocks":{"operation":"build_share_stats","args":[[],"all"]}}`,
		`{"share_stats":{"operation":"build_share_stats","args":[[{"ts":null}],"all"]}}`,
	} {
		t.Run(series, func(t *testing.T) {
			handler := New(Options{
				Inputs: func(context.Context, string, string) (json.RawMessage, error) {
					return json.RawMessage(`{"state":{},"chart":{},"series":` + series + `}`), nil
				},
				Reference: http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
					w.WriteHeader(299)
				}),
			})
			response := httptest.NewRecorder()
			handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/state", nil))
			if response.Code != 299 {
				t.Fatalf("response = %d, %s", response.Code, response.Body.String())
			}
		})
	}
}
