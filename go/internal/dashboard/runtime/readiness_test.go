package runtime

import (
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestReferenceReadinessChild(t *testing.T) {
	mode := os.Getenv("PITHEAD_DASHBOARD_READINESS_CHILD")
	if mode == "" {
		return
	}
	if mode == "fail" {
		os.Exit(23)
	}
	if mode == "delay" {
		time.Sleep(250 * time.Millisecond)
	}
	file := os.NewFile(3, "reference-listener")
	listener, err := net.FileListener(file)
	if err != nil {
		os.Exit(24)
	}
	_ = file.Close()
	_ = http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "ready")
	}))
	os.Exit(0)
}

func TestStartReferenceWaitsForChildReadiness(t *testing.T) {
	root := readinessRoot(t, "delay")
	started := time.Now()
	backend, err := startReference(root, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	defer backend.close()
	if elapsed := time.Since(started); elapsed < 200*time.Millisecond {
		t.Fatalf("start returned before delayed child was ready: %s", elapsed)
	}
	response := httptest.NewRecorder()
	backend.handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/", nil))
	if response.Code != http.StatusOK || response.Body.String() != "ready" {
		t.Fatalf("single request after start: %d %q", response.Code, response.Body.String())
	}
}

func TestStartReferenceReturnsFailedChildStartup(t *testing.T) {
	root := readinessRoot(t, "fail")
	started := time.Now()
	backend, err := startReference(root, io.Discard)
	if err == nil || backend != nil {
		if backend != nil {
			backend.close()
		}
		t.Fatal("failed child startup succeeded")
	}
	if elapsed := time.Since(started); elapsed > 3*time.Second {
		t.Fatalf("failed child startup took %s", elapsed)
	}
}

func readinessRoot(t *testing.T, mode string) string {
	t.Helper()
	t.Setenv("PITHEAD_DASHBOARD_REFERENCE_URL", "")
	t.Setenv("PITHEAD_DASHBOARD_READINESS_CHILD", mode)
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	python := filepath.Join(t.TempDir(), "python")
	script := "#!/bin/sh\nexec '" + strings.ReplaceAll(executable, "'", "'\\''") + "' -test.run=^TestReferenceReadinessChild$\n"
	if err := os.WriteFile(python, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PITHEAD_DASHBOARD_PYTHON", python)
	root := filepath.Join(t.TempDir(), "mining_dashboard", "web")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	return root
}
