package config

import (
	"errors"
	"reflect"
	"testing"
)

func TestProjectWorkerRead(t *testing.T) {
	raw := []byte(`{"workers":{"api_port":9000,"list":[{"name":"a","host":"h","token":"secret","port":9001},{"name":false,"host":null,"token":"two"},{"token":1},null]}}`)
	want := "{\"name\":\"a\",\"host\":\"h\",\"token\":\"secret\",\"port\":9001}\n{\"name\":\"\",\"host\":\"\",\"token\":\"two\",\"port\":9000}\n"
	got, err := ProjectWorkerRead(raw)
	if err != nil || string(got) != want {
		t.Fatalf("ProjectWorkerRead() = %q, %v", got, err)
	}
}

func TestProjectWorkerReadObjectList(t *testing.T) {
	raw := []byte(`{"workers":{"list":{"first":{"name":"a","host":"h","token":"t"},"second":null}}}`)
	want := "{\"name\":\"a\",\"host\":\"h\",\"token\":\"t\",\"port\":8080}\n"
	got, err := ProjectWorkerRead(raw)
	if err != nil || string(got) != want {
		t.Fatalf("ProjectWorkerRead() = %q, %v", got, err)
	}
}

func TestWorkerReadValues(t *testing.T) {
	got, err := WorkerReadValues([]byte(`{"name":"a","host":false,"token":"t","port":1}`))
	want := [][]byte{[]byte("a"), []byte("false"), []byte("t"), []byte("1")}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("WorkerReadValues() = %q, %v", got, err)
	}
}

func TestWorkerReadRecordAndSlurp(t *testing.T) {
	first, err := WorkerReadRecord("a", "h", "08080", "read")
	if err != nil {
		t.Fatal(err)
	}
	second, err := WorkerReadRecord("b", "h2", "1", "read2")
	if err != nil {
		t.Fatal(err)
	}
	got, err := SlurpWorkerRead(append(first, second...))
	want := "[\n  {\n    \"name\": \"a\",\n    \"host\": \"h\",\n    \"port\": 8080,\n    \"read_token\": \"read\"\n  },\n  {\n    \"name\": \"b\",\n    \"host\": \"h2\",\n    \"port\": 1,\n    \"read_token\": \"read2\"\n  }\n]\n"
	if err != nil || string(got) != want {
		t.Fatalf("SlurpWorkerRead() = %q, %v", got, err)
	}
}

func TestWorkerReadRefusals(t *testing.T) {
	for _, raw := range []string{
		`{"workers":1}`,
		`{"workers":{"list":[1]}}`,
		`{"workers":{"list":[{"token":"t","port":1.5}]}}`,
		`{"workers":{},"workers":{}}`,
	} {
		if output, err := ProjectWorkerRead([]byte(raw)); output != nil || !errors.Is(err, ErrUnsupportedWorkerRead) {
			t.Fatalf("ProjectWorkerRead(%q) = %q, %v", raw, output, err)
		}
	}
	for _, raw := range []string{"{\"name\":\"\\u0000\"}", "{\"name\":\"line\\nfeed\"}", "{\"name\":\"carriage\\rreturn\"}"} {
		if output, err := WorkerReadValues([]byte(raw)); output != nil || !errors.Is(err, ErrUnsupportedWorkerRead) {
			t.Fatalf("WorkerReadValues control = %q, %v", output, err)
		}
	}
	if output, err := WorkerReadRecord("a", "h", "0", "r"); output != nil || !errors.Is(err, ErrUnsupportedWorkerRead) {
		t.Fatalf("WorkerReadRecord port = %q, %v", output, err)
	}
	if output, err := WorkerReadRecord("a\nb", "h", "1", "r"); output != nil || !errors.Is(err, ErrUnsupportedWorkerRead) {
		t.Fatalf("WorkerReadRecord newline = %q, %v", output, err)
	}
	if output, err := SlurpWorkerRead([]byte(`{"a":1}{"a":1,"a":2}`)); output != nil || !errors.Is(err, ErrUnsupportedWorkerRead) {
		t.Fatalf("SlurpWorkerRead duplicate = %q, %v", output, err)
	}
}
