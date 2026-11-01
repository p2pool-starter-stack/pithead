package runtime

import (
	"context"
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

func TestReferenceProxy(t *testing.T) {
	for _, raw := range []string{"", "https://example.invalid", "http://user:pass@example.invalid", "http://example.invalid/path", "http://example.invalid?q=x", "http://example.invalid#x", "http://example.invalid", "http://0.0.0.0", "http://192.0.2.1", "http://[::]", "http://[ff02::1]"} {
		if _, err := referenceProxy(raw, nil); err == nil {
			t.Fatalf("accepted invalid reference URL %q", raw)
		}
	}
	upstream := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.RequestURI() != "/api/state?range=1h" || r.Method != http.MethodPost || r.Header.Get("X-Pithead-Control") != "1" {
			t.Errorf("request contract changed: %s %s", r.Method, r.URL.RequestURI())
		}
		body, _ := io.ReadAll(r.Body)
		if string(body) != "fixture" {
			t.Errorf("request body changed: %q", body)
		}
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusAccepted)
		_, _ = io.WriteString(w, `{"status":"pending"}`)
	}))
	backend, err := referenceProxy(upstream.URL, nil)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodPost, "/api/state?range=1h", strings.NewReader("fixture"))
	request.Header.Set("X-Pithead-Control", "1")
	response := httptest.NewRecorder()
	backend.handler.ServeHTTP(response, request)
	if response.Code != http.StatusAccepted || response.Body.String() != `{"status":"pending"}` || response.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("response contract changed: %#v", response.Result())
	}
	upstream.Close()
	response = httptest.NewRecorder()
	backend.handler.ServeHTTP(response, request)
	if response.Code != http.StatusBadGateway || response.Body.String() != "502: Bad Gateway" {
		t.Fatalf("unsanitized backend failure: %d %q", response.Code, response.Body.String())
	}
	backend.close()
}

func TestReferenceChild(t *testing.T) {
	if os.Getenv("PITHEAD_DASHBOARD_TEST_CHILD") != "1" {
		return
	}
	file := os.NewFile(3, "reference-listener")
	listener, err := net.FileListener(file)
	if err != nil {
		os.Exit(2)
	}
	_ = file.Close()
	_ = http.Serve(listener, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = io.WriteString(w, "reference-child")
	}))
	os.Exit(0)
}

func TestStartReferenceUsesInheritedListener(t *testing.T) {
	t.Setenv("PITHEAD_DASHBOARD_REFERENCE_URL", "")
	t.Setenv("PITHEAD_DASHBOARD_TEST_CHILD", "1")
	executable, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	python := filepath.Join(t.TempDir(), "python")
	script := "#!/bin/sh\nexec '" + strings.ReplaceAll(executable, "'", "'\\''") + "' -test.run=^TestReferenceChild$\n"
	if err := os.WriteFile(python, []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PITHEAD_DASHBOARD_PYTHON", python)
	root := filepath.Join(t.TempDir(), "mining_dashboard", "web")
	if err := os.MkdirAll(root, 0700); err != nil {
		t.Fatal(err)
	}
	backend, err := startReference(root, io.Discard)
	if err != nil {
		t.Fatal(err)
	}
	defer backend.close()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	response := httptest.NewRecorder()
	backend.handler.ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/api/state", nil).WithContext(ctx))
	if response.Code != http.StatusOK || response.Body.String() != "reference-child" {
		t.Fatalf("reference child response: %d %q", response.Code, response.Body.String())
	}
	backend.close()
	select {
	case <-backend.done:
	default:
		t.Fatal("reference child survived shutdown")
	}
}
