package doctor

import (
	"bytes"
	"errors"
	"os/exec"
	"strconv"
	"testing"
)

const jqReport = `split("\n") | map(select(length > 0) | split("\t") | {id: .[2], status: .[0], message: .[1]})
 | {version: $version, exit: $rc,
    summary: {ok: map(select(.status == "ok")) | length,
              warn: map(select(.status == "warn")) | length,
              fail: map(select(.status == "fail")) | length,
              info: map(select(.status == "info")) | length},
    checks: .}`

func TestWriteJSON(t *testing.T) {
	rows := []byte("ok\tAll good.\tdependency-jq\n\nwarn\tCareful.\twarn-id\textra\nfail-only\ninfo\t\t\nunknown\ttext\tid\n")
	want := `{
  "version": "2.1.0",
  "exit": 7,
  "summary": {
    "ok": 1,
    "warn": 1,
    "fail": 0,
    "info": 1
  },
  "checks": [
    {
      "id": "dependency-jq",
      "status": "ok",
      "message": "All good."
    },
    {
      "id": "warn-id",
      "status": "warn",
      "message": "Careful."
    },
    {
      "id": null,
      "status": "fail-only",
      "message": null
    },
    {
      "id": "",
      "status": "info",
      "message": ""
    },
    {
      "id": "id",
      "status": "unknown",
      "message": "text"
    }
  ]
}
`
	var got bytes.Buffer
	if err := WriteJSON(&got, "2.1.0", 7, rows); err != nil {
		t.Fatal(err)
	}
	if got.String() != want {
		t.Fatalf("output mismatch\n got: %q\nwant: %q", got.String(), want)
	}
}

func TestWriteJSONMatchesJQ(t *testing.T) {
	var versionControls, messageControls []byte
	for value := byte(0); value < 0x20; value++ {
		if value != 0 {
			versionControls = append(versionControls, value)
		}
		if value != '\t' && value != '\n' {
			messageControls = append(messageControls, value)
		}
	}
	versionControls = append(versionControls, 0x7f)
	messageControls = append(messageControls, 0x7f)
	cutUTF8 := []byte{0xc2, '|', 0xe2, '|', 0xe2, 0x82, '|', 0xf0, '|', 0xf0, 0x9f, '|', 0xf0, 0x9f, 0x92, '|'}
	illegalUTF8 := []byte{0x80, 0xbf, 0xc0, 0xc1, 0xf5, 0xff, '|', 0xe0, 0x80, 0x80, '|', 0xed, 0xa0, 0x80, '|', 0xf0, 0x80, 0x80, 0x80, '|', 0xf4, 0x90, 0x80, 0x80}
	fixtures := []struct {
		name    string
		version string
		exit    int
		rows    []byte
	}{
		{name: "empty", version: "fixture", rows: nil},
		{name: "statuses", version: "v2.1.0", exit: 1, rows: []byte("ok\tone\ta\nwarn\ttwo\tb\nfail\tthree\tc\ninfo\tfour\td")},
		{name: "missing and extra fields", version: "fields", exit: 9, rows: []byte("status\nstatus\tmessage\nstatus\tmessage\tid\textra\n\r\n")},
		{name: "escaping", version: "<version>&\u2028", exit: -3, rows: []byte("ok\t<>&     \\u2028 \\ \tid\n")},
		{name: "invalid utf8", version: string([]byte{'v', 0xff}), rows: []byte{'o', 'k', '\t', 0xff, 0xc0, 0xaf, 0xe2, 0x28, 0xa1, 0xf0, 0x28, 0x8c, 0xbc, 0xe2, 0x82, 0xe0, 0x80, 0x80, 0xed, 0xa0, 0x80, 0xf4, 0x90, 0x80, 0x80, '\t', 'i', 'd', '\n'}},
		{name: "ascii controls", version: string(versionControls), rows: reportRow(messageControls)},
		{name: "truncated utf8", version: "cuts", rows: reportRow(cutUTF8)},
		{name: "illegal utf8 stems", version: "illegal", rows: reportRow(illegalUTF8)},
		{name: "wide unicode", version: "雪🙂\U0010ffff", rows: reportRow([]byte("éλ雪🙂\U0010ffff"))},
	}
	for _, fixture := range fixtures {
		t.Run(fixture.name, func(t *testing.T) {
			var got bytes.Buffer
			if err := WriteJSON(&got, fixture.version, fixture.exit, fixture.rows); err != nil {
				t.Fatal(err)
			}
			command := exec.Command("jq", "-Rs", "--arg", "version", fixture.version, "--argjson", "rc", strconv.Itoa(fixture.exit), jqReport)
			command.Stdin = bytes.NewReader(fixture.rows)
			want, err := command.CombinedOutput()
			if err != nil {
				t.Fatalf("jq: %v: %s", err, want)
			}
			if !bytes.Equal(got.Bytes(), want) {
				t.Fatalf("output mismatch\n got: %q\nwant: %q", got.Bytes(), want)
			}
		})
	}
}

func reportRow(message []byte) []byte {
	row := append([]byte("ok\t"), message...)
	return append(row, '\t', 'i', 'd', '\n')
}

func TestWriteJSONReturnsWriterError(t *testing.T) {
	want := errors.New("write failed")
	if err := WriteJSON(errorWriter{want}, "fixture", 0, nil); !errors.Is(err, want) {
		t.Fatalf("error = %v, want %v", err, want)
	}
}

type errorWriter struct {
	err error
}

func (w errorWriter) Write([]byte) (int, error) {
	return 0, w.err
}
