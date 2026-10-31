package doctor

import (
	"bytes"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"reflect"
	"strconv"
	"strings"
	"syscall"
	"testing"
)

func TestProbeEnv(t *testing.T) {
	env := []string{"PATH=/bin", "NO_COLOR=old", "DR_JSON_FILE=old", "KEEP=value", "NO_COLOR=duplicate"}
	want := []string{"PATH=/bin", "KEEP=value", "DR_JSON_FILE=new", "NO_COLOR=1", "PITHEAD_GO_DOCTOR_DONE=new.done"}
	if got := probeEnv(env, "new"); !reflect.DeepEqual(got, want) {
		t.Fatalf("probeEnv = %q, want %q", got, want)
	}
	if env[1] != "NO_COLOR=old" {
		t.Fatal("input environment changed")
	}
}

func TestRunJSONProbeAndCleanup(t *testing.T) {
	for _, code := range []int{0, 1} {
		t.Run(strconv.Itoa(code), func(t *testing.T) {
			dir := t.TempDir()
			t.Setenv("TMPDIR", dir)
			reference := filepath.Join(dir, "reference with spaces")
			body := "#!/bin/bash\n[ \"$1\" = doctor ] || exit 99\n" +
				"[ \"$PITHEAD_IMPL\" = bash ] || exit 98\n" +
				"[ \"$NO_COLOR\" = 1 ] || exit 97\n" +
				"printf 'ok\\tReady.\\tprobe\\n' >>\"$DR_JSON_FILE\"\n" +
				": >\"$PITHEAD_GO_DOCTOR_DONE\"\n" +
				"printf 'human output\\n'\nprintf 'probe warning\\n' >&2\nexit " + strconv.Itoa(code) + "\n"
			if err := os.WriteFile(reference, []byte(body), 0o700); err != nil {
				t.Fatal(err)
			}
			var out, stderr bytes.Buffer
			runner := Runner{Reference: reference, Version: "fixture", Env: append(os.Environ(), "PITHEAD_IMPL=bash"), Out: &out, Err: &stderr}
			got, err := runner.RunJSON()
			if err != nil || got != code {
				t.Fatalf("RunJSON = %d, %v", got, err)
			}
			var report struct {
				Version string `json:"version"`
				Exit    int    `json:"exit"`
			}
			if err := json.Unmarshal(out.Bytes(), &report); err != nil || report.Version != "fixture" || report.Exit != code {
				t.Fatalf("report = %s, error %v", out.Bytes(), err)
			}
			if stderr.String() != "human output\nprobe warning\n" {
				t.Fatalf("stderr = %q", stderr.String())
			}
			entries, err := os.ReadDir(dir)
			if err != nil || len(entries) != 1 || entries[0].Name() != filepath.Base(reference) {
				t.Fatalf("temporary rows retained: %v, %v", entries, err)
			}
		})
	}
}

func TestRunJSONMissingToolsFallsBack(t *testing.T) {
	t.Setenv("PATH", t.TempDir())
	var out, stderr bytes.Buffer
	_, err := (Runner{Reference: "must not execute", Out: &out, Err: &stderr}).RunJSON()
	if !errors.Is(err, ErrFallback) || out.Len() != 0 || stderr.Len() != 0 {
		t.Fatalf("fallback = %v, stdout %q, stderr %q", err, out.String(), stderr.String())
	}
}

func TestRunJSONBrokenPipe(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("TMPDIR", dir)
	reference := filepath.Join(dir, "reference")
	if err := os.WriteFile(reference, []byte(": >\"$PITHEAD_GO_DOCTOR_DONE\"\nexit 1\n"), 0o700); err != nil {
		t.Fatal(err)
	}
	code, err := (Runner{Reference: reference, Env: os.Environ(), Out: pipeWriter{}, Err: &strings.Builder{}}).RunJSON()
	if err != nil || code != 1 {
		t.Fatalf("closed stdout changed probe result: %d, %v", code, err)
	}
}

type pipeWriter struct{}

func (pipeWriter) Write([]byte) (int, error) { return 0, syscall.EPIPE }
