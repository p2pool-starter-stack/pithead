package web

import (
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestRoutes(t *testing.T) {
	base := Routes(false)
	withControl := Routes(true)
	expected := []Route{
		{http.MethodGet, "/"},
		{http.MethodGet, "/api/state"},
		{http.MethodGet, "/api/miner-connection"},
		{http.MethodGet, "/api/xvb-standby"},
		{http.MethodGet, "/metrics"},
		{http.MethodGet, "/api/access"},
		{http.MethodGet, "/ui-preview"},
		{http.MethodGet, "/static/{tail:.*}"},
		{http.MethodGet, "/api/config"},
		{http.MethodPost, "/api/control/preview"},
		{http.MethodPost, "/api/control/commit"},
		{http.MethodPost, "/api/control/upgrade"},
		{http.MethodGet, "/api/control/result"},
		{http.MethodGet, "/api/audit"},
		{http.MethodGet, "/api/worker"},
		{http.MethodPost, "/api/control/worker-apply"},
		{http.MethodPost, "/api/control/worker-upgrade"},
		{http.MethodPost, "/api/control/backup"},
		{http.MethodGet, "/api/control/backup-download"},
		{http.MethodPost, "/api/control/os-update"},
		{http.MethodPost, "/api/control/diag-doctor"},
		{http.MethodPost, "/api/control/diag-logs"},
		{http.MethodPost, "/api/control/onion-client-key"},
	}
	if !reflect.DeepEqual(base, expected[:8]) || !reflect.DeepEqual(withControl, expected) {
		t.Fatalf("routes = %#v", withControl)
	}
	withControl[0].Pattern = "/changed"
	if Routes(true)[0].Pattern != "/" {
		t.Fatal("Routes returned shared storage")
	}
}

func TestNativeShellAndPreview(t *testing.T) {
	root := webRoot(t)
	h := New(Options{WebRoot: root})

	assertResponse(t, h, http.MethodGet, "/", http.StatusOK, "shell\n", "text/html; charset=utf-8")
	assertResponse(t, h, http.MethodHead, "/", http.StatusOK, "", "text/html; charset=utf-8")
	assertResponse(t, h, http.MethodGet, "/ui-preview", http.StatusNotFound, "404: Not Found", "text/plain; charset=utf-8")

	h = New(Options{WebRoot: root, PreviewEnabled: true})
	recorder := request(h, http.MethodGet, "/ui-preview", nil)
	if recorder.Code != http.StatusOK || recorder.Body.String() != "preview\n" {
		t.Fatalf("preview = %d %q", recorder.Code, recorder.Body.String())
	}
	if recorder.Header().Get("Cache-Control") != "no-store" {
		t.Fatalf("preview cache = %q", recorder.Header().Get("Cache-Control"))
	}
}

func TestShellCache(t *testing.T) {
	root := webRoot(t)
	h := New(Options{WebRoot: root})
	assertResponse(t, h, http.MethodGet, "/", http.StatusOK, "shell\n", "text/html; charset=utf-8")
	path := filepath.Join(root, "templates", "index.html")
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	assertResponse(t, h, http.MethodGet, "/", http.StatusOK, "shell\n", "text/html; charset=utf-8")

	empty := New(Options{WebRoot: t.TempDir()})
	assertResponse(t, empty, http.MethodGet, "/", http.StatusOK, "<h1>Dashboard shell error</h1>", "text/html; charset=utf-8")
}

func TestShellTextSemantics(t *testing.T) {
	root := webRoot(t)
	path := filepath.Join(root, "templates", "index.html")
	if err := os.WriteFile(path, []byte("one\r\ntwo\rthree\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	h := New(Options{WebRoot: root})
	assertResponse(t, h, http.MethodGet, "/", http.StatusOK, "one\ntwo\nthree\n", "text/html; charset=utf-8")

	for _, content := range [][]byte{{}, {0xff}} {
		emptyRoot := webRoot(t)
		if err := os.WriteFile(filepath.Join(emptyRoot, "templates", "index.html"), content, 0o644); err != nil {
			t.Fatal(err)
		}
		empty := New(Options{WebRoot: emptyRoot})
		assertResponse(t, empty, http.MethodGet, "/", http.StatusOK, "<h1>Dashboard shell error</h1>", "text/html; charset=utf-8")
	}
}

func TestRouteGuardsAndReference(t *testing.T) {
	var calls []string
	reference := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls = append(calls, r.Method+" "+r.URL.Path)
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"ok":true}`)
	})
	h := New(Options{WebRoot: webRoot(t), Reference: reference})

	assertResponse(t, h, http.MethodGet, "/api/state", http.StatusOK, `{"ok":true}`, "application/json")
	assertResponse(t, h, http.MethodHead, "/api/state", http.StatusOK, `{"ok":true}`, "application/json")
	assertResponse(t, h, http.MethodPost, "/api/state", http.StatusMethodNotAllowed, "405: Method Not Allowed", "text/plain; charset=utf-8")
	assertResponse(t, h, http.MethodGet, "/api/config", http.StatusNotFound, "404: Not Found", "text/plain; charset=utf-8")
	assertResponse(t, h, http.MethodGet, "/missing", http.StatusNotFound, "404: Not Found", "text/plain; charset=utf-8")
	if !reflect.DeepEqual(calls, []string{"GET /api/state", "HEAD /api/state"}) {
		t.Fatalf("reference calls = %#v", calls)
	}

	response := request(h, http.MethodPost, "/api/state", nil)
	if response.Header().Get("Allow") != "GET,HEAD" {
		t.Fatalf("allow = %q", response.Header().Get("Allow"))
	}

	h = New(Options{WebRoot: webRoot(t), ControlEnabled: true, Reference: reference})
	assertResponse(t, h, http.MethodPost, "/api/control/backup", http.StatusOK, `{"ok":true}`, "application/json")
	assertResponse(t, h, http.MethodGet, "/api/control/backup", http.StatusMethodNotAllowed, "405: Method Not Allowed", "text/plain; charset=utf-8")
	if got := request(h, http.MethodGet, "/api/control/backup", nil).Header().Get("Allow"); got != "POST" {
		t.Fatalf("control allow = %q", got)
	}
}

func TestNilReferenceIsSanitized(t *testing.T) {
	h := New(Options{WebRoot: webRoot(t)})
	assertResponse(t, h, http.MethodGet, "/api/state", http.StatusServiceUnavailable, "503: Service Unavailable", "text/plain; charset=utf-8")
}

func TestSecurityHeaders(t *testing.T) {
	reference := http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("X-Frame-Options", "SAMEORIGIN")
		w.Header().Set("Cache-Control", "no-store")
		w.WriteHeader(http.StatusTeapot)
	})
	h := New(Options{WebRoot: webRoot(t), Reference: reference})
	for _, path := range []string{"/", "/api/state", "/missing"} {
		response := request(h, http.MethodGet, path, nil)
		for key, value := range map[string]string{
			"X-Content-Type-Options":  "nosniff",
			"X-Frame-Options":         "DENY",
			"Referrer-Policy":         "no-referrer",
			"Content-Security-Policy": contentSecurityPolicy,
		} {
			if response.Header().Get(key) != value {
				t.Fatalf("%s %s = %q", path, key, response.Header().Get(key))
			}
		}
	}
	if got := request(h, http.MethodGet, "/api/state", nil).Header().Get("Cache-Control"); got != "no-store" {
		t.Fatalf("reference cache = %q", got)
	}
}

func TestSecurityHeadersOnEmptyReferenceResponse(t *testing.T) {
	h := New(Options{WebRoot: webRoot(t), Reference: http.HandlerFunc(func(http.ResponseWriter, *http.Request) {})})
	response := request(h, http.MethodGet, "/api/state", nil)
	if response.Code != http.StatusOK || response.Header().Get("X-Frame-Options") != "DENY" {
		t.Fatalf("empty response = %d %#v", response.Code, response.Header())
	}
}

func TestStaticFiles(t *testing.T) {
	root := webRoot(t)
	path := filepath.Join(root, "static", "app", "main.mjs")
	mtime := time.Unix(1_700_000_000, 123_456_789)
	if err := os.Chtimes(path, mtime, mtime); err != nil {
		t.Fatal(err)
	}
	h := New(Options{WebRoot: root})
	response := request(h, http.MethodGet, "/static/app/main.mjs", nil)
	if response.Code != http.StatusOK || response.Body.String() != "module\n" {
		t.Fatalf("static = %d %q", response.Code, response.Body.String())
	}
	if response.Header().Get("Content-Type") != "application/javascript" {
		t.Fatalf("content type = %q", response.Header().Get("Content-Type"))
	}
	if response.Header().Get("Cache-Control") != "no-cache" || response.Header().Get("Accept-Ranges") != "bytes" {
		t.Fatalf("static headers = %#v", response.Header())
	}
	etag := response.Header().Get("Etag")
	if etag == "" || response.Header().Get("Last-Modified") != time.Unix(1_700_000_001, 0).UTC().Format(http.TimeFormat) {
		t.Fatalf("metadata = %#v", response.Header())
	}

	conditional := request(h, http.MethodGet, "/static/app/main.mjs", map[string]string{"If-None-Match": etag})
	if conditional.Code != http.StatusNotModified || conditional.Body.Len() != 0 {
		t.Fatalf("conditional = %d %q", conditional.Code, conditional.Body.String())
	}
	if conditional.Header().Get("Last-Modified") != time.Unix(1_700_000_001, 0).UTC().Format(http.TimeFormat) {
		t.Fatalf("conditional metadata = %#v", conditional.Header())
	}
	ranged := request(h, http.MethodGet, "/static/app/main.mjs", map[string]string{"Range": "bytes=1-3"})
	if ranged.Code != http.StatusPartialContent || ranged.Body.String() != "odu" {
		t.Fatalf("range = %d %q", ranged.Code, ranged.Body.String())
	}
	head := request(h, http.MethodHead, "/static/app/main.mjs", nil)
	if head.Code != http.StatusOK || head.Body.Len() != 0 || head.Header().Get("Content-Length") != "7" {
		t.Fatalf("head = %d %q %#v", head.Code, head.Body.String(), head.Header())
	}
}

func TestJavaScriptContentTypes(t *testing.T) {
	for _, name := range []string{"app.js", "app.mjs"} {
		if got := contentType(name); got != "application/javascript" {
			t.Fatalf("%s content type = %q", name, got)
		}
	}
}

func TestStaticTraversalAndSymlinks(t *testing.T) {
	root := webRoot(t)
	outside := t.TempDir()
	if err := os.MkdirAll(filepath.Join(root, "static", "app", "deep"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outside, "secret"), []byte("secret"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "static", "app", "main.mjs"), filepath.Join(root, "static", "inside")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(outside, "secret"), filepath.Join(root, "static", "outside")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink(filepath.Join(root, "static", "app", "deep"), filepath.Join(root, "static", "nested")); err != nil {
		t.Fatal(err)
	}
	h := New(Options{WebRoot: root})
	assertResponse(t, h, http.MethodGet, "/static/inside", http.StatusOK, "module\n", "application/javascript")
	for _, path := range []string{"/static/app/./main.mjs", "/static/app//main.mjs", "/static/app/../app/main.mjs", "/static/nested/../main.mjs"} {
		assertResponse(t, h, http.MethodGet, path, http.StatusOK, "module\n", "application/javascript")
	}
	for _, path := range []string{"/static/outside", "/static/../secret", "/static//app/main.mjs"} {
		assertResponse(t, h, http.MethodGet, path, http.StatusNotFound, "404: Not Found", "text/plain; charset=utf-8")
	}
	assertResponse(t, h, http.MethodGet, "/static", http.StatusForbidden, "403: Forbidden", "text/plain; charset=utf-8")
	assertResponse(t, h, http.MethodGet, "/static/app", http.StatusForbidden, "403: Forbidden", "text/plain; charset=utf-8")
	for _, path := range []string{"/static/missing.js", "/static/app/../missing.js"} {
		response := request(h, http.MethodGet, path, nil)
		if response.Code != http.StatusNotFound || response.Body.Len() != 0 || response.Header().Get("Content-Type") != "application/octet-stream" {
			t.Fatalf("missing static = %d %q %#v", response.Code, response.Body.String(), response.Header())
		}
	}
}

func webRoot(t *testing.T) string {
	t.Helper()
	root := t.TempDir()
	for path, content := range map[string]string{
		"templates/index.html":     "shell\n",
		"templates/sovereign.html": "preview\n",
		"static/app/main.mjs":      "module\n",
	} {
		full := filepath.Join(root, filepath.FromSlash(path))
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(content), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return root
}

func request(h http.Handler, method, target string, headers map[string]string) *httptest.ResponseRecorder {
	req := httptest.NewRequest(method, target, nil)
	for key, value := range headers {
		req.Header.Set(key, value)
	}
	recorder := httptest.NewRecorder()
	h.ServeHTTP(recorder, req)
	return recorder
}

func assertResponse(t *testing.T, h http.Handler, method, path string, status int, body, contentType string) {
	t.Helper()
	response := request(h, method, path, nil)
	if response.Code != status || response.Body.String() != body {
		t.Fatalf("%s %s = %d %q", method, path, response.Code, response.Body.String())
	}
	if got := response.Header().Get("Content-Type"); got != contentType {
		t.Fatalf("%s %s content type = %q", method, path, got)
	}
	if response.Header().Get("Cache-Control") == "" {
		t.Fatalf("%s %s missing cache control", method, path)
	}
}
