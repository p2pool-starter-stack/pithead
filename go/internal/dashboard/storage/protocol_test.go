package storage

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func protocolReplies(t *testing.T, requests ...map[string]any) []map[string]any {
	t.Helper()
	var input, output bytes.Buffer
	for _, request := range requests {
		if err := json.NewEncoder(&input).Encode(request); err != nil {
			t.Fatal(err)
		}
	}
	if err := Run(&input, &output); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(output.String()), "\n")
	if len(lines) != len(requests) {
		t.Fatalf("received %d replies for %d requests", len(lines), len(requests))
	}
	replies := make([]map[string]any, len(lines))
	for index, line := range lines {
		if err := json.Unmarshal([]byte(line), &replies[index]); err != nil {
			t.Fatal(err)
		}
	}
	return replies
}

func TestProtocolTransactionsAndRows(t *testing.T) {
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "execute", "sql": "INSERT INTO kv_store VALUES (?, ?)", "args": []any{"rollback", "value"}},
		map[string]any{"op": "rollback"},
		map[string]any{"op": "execute", "sql": "SELECT * FROM kv_store"},
		map[string]any{"op": "executemany", "sql": "INSERT INTO kv_store VALUES (?, ?)", "args_list": [][]any{{"one", "first"}, {"two", "second"}}},
		map[string]any{"op": "commit"},
		map[string]any{"op": "execute", "sql": "SELECT value FROM kv_store ORDER BY key"},
	)
	for index, reply := range replies {
		if reply["ok"] != true {
			t.Fatalf("request %d: %#v", index, reply)
		}
	}
	if rows := replies[4]["result"].(map[string]any)["rows"].([]any); len(rows) != 0 {
		t.Fatal(rows)
	}
	batch := replies[5]["result"].(map[string]any)
	if batch["rowcount"] != float64(2) {
		t.Fatal(batch)
	}
	rows := replies[7]["result"].(map[string]any)["rows"].([]any)
	if len(rows) != 2 || rows[0].([]any)[0] != "first" || rows[1].([]any)[0] != "second" {
		t.Fatal(rows)
	}
}

func TestProtocolRecoveryFailuresAndRetry(t *testing.T) {
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "recover", "reason": "open failed", "open_error": "unable to open database file"},
		map[string]any{"op": "recover", "reason": "schema failed", "schema_error": "disk full"},
		map[string]any{"op": "recover", "reason": "retry"},
	)
	for _, index := range []int{2, 3} {
		reply := replies[index]
		health := reply["health"].(map[string]any)
		if reply["ok"] != false || health["healthy"] != false || health["unrecoverable"] != true || health["reset_count"] != float64(0) {
			t.Fatal(reply)
		}
	}
	if replies[2]["connected"] != false || replies[3]["connected"] != true {
		t.Fatal(replies)
	}
	health := replies[4]["health"].(map[string]any)
	if replies[4]["ok"] != true || health["healthy"] != true || health["unrecoverable"] != false || health["reset_count"] != float64(1) {
		t.Fatal(replies[4])
	}
	reset := health["last_reset"].(map[string]any)
	if reset["reason"] != "retry" || reset["quarantine"] != nil {
		t.Fatal(reset)
	}
}

func TestProtocolSQLiteTypesAndErrors(t *testing.T) {
	replies := protocolReplies(t,
		map[string]any{"op": "open", "path": ":memory:"},
		map[string]any{"op": "execute", "sql": "SELECT ?, ?, ?, ?", "args": []any{int64(9223372036854775807), map[string]any{"$bytes": "AP8="}, map[string]any{"$float": "inf"}, map[string]any{"$float": "nan"}}},
		map[string]any{"op": "execute", "sql": "SELECT * FROM absent"},
		map[string]any{"op": "initialize"},
		map[string]any{"op": "execute", "sql": "INSERT INTO kv_store VALUES ('one','first')"},
		map[string]any{"op": "execute", "sql": "INSERT INTO kv_store VALUES ('one','duplicate')"},
		map[string]any{"op": "execute", "sql": "SELECT ?", "args": []any{json.Number("9223372036854775808")}},
	)
	if replies[1]["ok"] != true {
		t.Fatal(replies[1])
	}
	row := replies[1]["result"].(map[string]any)["rows"].([]any)[0].([]any)
	if row[1].(map[string]any)["$bytes"] != "AP8=" || row[2].(map[string]any)["$float"] != "inf" || row[3] != nil {
		t.Fatal(row)
	}
	if replies[2]["ok"] != false || replies[2]["error"] != "no such table: absent" || replies[2]["error_kind"] != "OperationalError" {
		t.Fatal(replies[2])
	}
	if replies[5]["error_kind"] != "IntegrityError" {
		t.Fatal(replies[5])
	}
	if replies[6]["error_kind"] != "OverflowError" || replies[6]["error"] != "Python int too large to convert to SQLite INTEGER" {
		t.Fatal(replies[6])
	}
}
