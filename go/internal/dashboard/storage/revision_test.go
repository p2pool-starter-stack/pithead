package storage

import (
	"bytes"
	"encoding/json"
	"math"
	"strings"
	"testing"
)

func revisionReplyResult(t *testing.T, reply map[string]any) map[string]any {
	t.Helper()
	if reply["ok"] != true {
		t.Fatal(reply)
	}
	result, ok := reply["result"].(map[string]any)
	if !ok {
		t.Fatalf("result = %#v", reply["result"])
	}
	return result
}

func TestWorkerRevisionPrepareClassifier(t *testing.T) {
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig1", "aaa", nil}},
		map[string]any{"op": "worker-revision-write", "args": []any{"rig1", "aaa", "c1", 10, "origin"}},
		map[string]any{"op": "commit"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig1", "aaa", "c1"}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig1", "bbb", "c1"}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig1", "bbb", "c2"}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig1", "bbb", nil}},
		map[string]any{"op": "worker-revision-write", "args": []any{"rig2", "aaa", nil, 10, nil}},
		map[string]any{"op": "commit"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig2", "aaa", nil}},
	)

	absent := revisionReplyResult(t, replies[2])
	if absent["row"] != nil || absent["next_slot"] != nil {
		t.Fatal(absent)
	}
	same := revisionReplyResult(t, replies[5])
	row := same["row"].([]any)
	if len(row) != 3 || row[0] != "aaa" || row[1] != "c1" || row[2] != "origin" || same["next_slot"] != float64(2) {
		t.Fatal(same)
	}
	if moved := revisionReplyResult(t, replies[6]); moved["next_slot"] != float64(0) {
		t.Fatal(moved)
	}
	for _, index := range []int{7, 8} {
		if cleared := revisionReplyResult(t, replies[index]); cleared["next_slot"] != nil {
			t.Fatal(cleared)
		}
	}
	carriedNil := revisionReplyResult(t, replies[11])
	if row := carriedNil["row"].([]any); row[2] != nil || carriedNil["next_slot"] != float64(2) {
		t.Fatal(carriedNil)
	}
}

func TestWorkerRevisionTransactionPruneAndCurrency(t *testing.T) {
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "worker-revision-write", "args": []any{"old", "aaa", nil, 10, "before"}},
		map[string]any{"op": "rollback"},
		map[string]any{"op": "worker-revision-drift", "args": []any{"old", "aaa"}},
		map[string]any{"op": "worker-revision-write", "args": []any{"old", "aaa", nil, 10, "before"}},
		map[string]any{"op": "worker-revision-write", "args": []any{"new", "bbb", nil, 20, nil}},
		map[string]any{"op": "commit"},
		map[string]any{"op": "worker-revision-drift", "args": []any{"old", "aaa"}},
		map[string]any{"op": "worker-revision-drift", "args": []any{"old", "zzz"}},
		map[string]any{"op": "worker-revision-prune", "args": []any{15}},
		map[string]any{"op": "rollback"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"old", "aaa", nil}},
		map[string]any{"op": "worker-revision-prune", "args": []any{15}},
		map[string]any{"op": "commit"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"old", "aaa", nil}},
	)
	for _, index := range []int{2, 5, 6, 10, 13} {
		if replies[index]["ok"] != true || replies[index]["result"] != nil {
			t.Fatalf("request %d: %#v", index, replies[index])
		}
	}

	if drift := revisionReplyResult(t, replies[4]); drift["visible"] != false || drift["row"] != nil {
		t.Fatal(drift)
	}
	if drift := revisionReplyResult(t, replies[8]); drift["visible"] != true {
		t.Fatal(drift)
	} else if row := drift["row"].([]any); len(row) != 2 || row[0] != "aaa" || row[1] != "before" {
		t.Fatal(drift)
	}
	if drift := revisionReplyResult(t, replies[9]); drift["visible"] != false {
		t.Fatal(drift)
	}
	if row := revisionReplyResult(t, replies[12]); row["row"] == nil {
		t.Fatal(row)
	}
	if row := revisionReplyResult(t, replies[15]); row["row"] != nil {
		t.Fatal(row)
	}
}

func TestWorkerRevisionScalarRowsAndTruthiness(t *testing.T) {
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "execute", "sql": "INSERT INTO worker_config_revision VALUES (?, ?, ?, ?, ?)", "args": []any{"bytes", map[string]any{"$bytes": "YWJj"}, nil, 1, map[string]any{"$bytes": "AP8="}}},
		map[string]any{"op": "execute", "sql": "INSERT INTO worker_config_revision VALUES (?, ?, ?, ?, ?)", "args": []any{"zero", "rev", nil, 1, 0}},
		map[string]any{"op": "execute", "sql": "INSERT INTO worker_config_revision VALUES (?, ?, ?, ?, ?)", "args": []any{"nan", "rev", nil, 1, map[string]any{"$float": "nan"}}},
		map[string]any{"op": "commit"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"bytes", "next", nil}},
		map[string]any{"op": "worker-revision-drift", "args": []any{"zero", "rev"}},
		map[string]any{"op": "worker-revision-drift", "args": []any{"nan", "rev"}},
	)

	prepared := revisionReplyResult(t, replies[6])
	row := prepared["row"].([]any)
	encoded, ok := row[0].(map[string]any)
	if !ok || encoded["$bytes"] != "YWJj" || prepared["next_slot"] != float64(0) {
		t.Fatal(prepared)
	}
	if zero := revisionReplyResult(t, replies[7]); zero["visible"] != true {
		t.Fatal(zero)
	} else if row := zero["row"].([]any); row[1] != "0" {
		t.Fatal(zero)
	}
	nan := revisionReplyResult(t, replies[8])
	if nan["visible"] != false {
		t.Fatal(nan)
	}
}

func TestRevisionTruthy(t *testing.T) {
	cases := []struct {
		value any
		want  bool
	}{
		{nil, false}, {false, false}, {true, true}, {"", false}, {"x", true},
		{[]byte{}, false}, {[]byte{0}, true}, {int64(0), false}, {int64(-1), true},
		{float64(0), false}, {math.NaN(), true},
	}
	for _, test := range cases {
		if got := revisionTruthy(test.value); got != test.want {
			t.Fatalf("revisionTruthy(%#v) = %v, want %v", test.value, got, test.want)
		}
	}
}

func TestWorkerRevisionProtocolRejectsMalformedRequests(t *testing.T) {
	long := strings.Repeat("x", revisionTextLimit+1)
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig"}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"", "rev", nil}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{long, "rev", nil}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig", long, nil}},
		map[string]any{"op": "worker-revision-prepare", "args": []any{"rig", "rev", long}},
		map[string]any{"op": "worker-revision-write", "args": []any{"rig", "rev", nil, true, nil}},
		map[string]any{"op": "worker-revision-write", "args": []any{"rig", "rev", nil, 1, []any{"bad"}}},
		map[string]any{"op": "worker-revision-prune", "args": []any{"old"}},
		map[string]any{"op": "worker-revision-drift", "args": []any{"rig", "rev", nil}},
	)
	for index := 2; index < len(replies); index++ {
		if replies[index]["ok"] != false || replies[index]["error_kind"] != "ProgrammingError" {
			t.Fatalf("request %d: %#v", index, replies[index])
		}
	}
}

func TestWorkerRevisionTextBoundary(t *testing.T) {
	text := strings.Repeat("x", revisionTextLimit)
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "worker-revision-prepare", "args": []any{text, text, text}},
	)
	result := revisionReplyResult(t, replies[2])
	if result["row"] != nil || result["next_slot"] != nil {
		t.Fatal(result)
	}
}

func TestStorageProtocolRejectsInvalidUTF8AndContinues(t *testing.T) {
	input := append([]byte{'{', '"', 'o', 'p', '"', ':', '"'}, 0xff)
	input = append(input, []byte("\"}\n{\"op\":\"classify\",\"message\":\"ok\"}\n")...)
	var output bytes.Buffer
	if err := Run(bytes.NewReader(input), &output); err != nil {
		t.Fatal(err)
	}
	decoder := json.NewDecoder(&output)
	var first, second map[string]any
	if err := decoder.Decode(&first); err != nil {
		t.Fatal(err)
	}
	if err := decoder.Decode(&second); err != nil {
		t.Fatal(err)
	}
	if first["ok"] != false || first["error_kind"] != "ProgrammingError" || second["ok"] != true {
		t.Fatal(first, second)
	}
}
