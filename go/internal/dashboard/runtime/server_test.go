package runtime

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"syscall"
	"testing"
	"time"
)

func TestInvalidListenerDescriptor(t *testing.T) {
	for _, value := range []string{"not-a-number", "-1", "0", "2", "999999"} {
		t.Setenv("PITHEAD_DASHBOARD_LISTEN_FD", value)
		if listener, err := listen(); err == nil {
			_ = listener.Close()
			t.Fatalf("accepted listener descriptor %q", value)
		}
	}
}

func TestRunServesNativeAndReferenceRoutes(t *testing.T) {
	root := t.TempDir()
	if err := os.Mkdir(filepath.Join(root, "templates"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "templates", "index.html"), []byte("native-shell"), 0600); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PITHEAD_DASHBOARD_WEB_ROOT", root)
	t.Setenv("DASHBOARD_CONTROL_ENABLED", "false")
	t.Setenv("DASHBOARD_UI_PREVIEW", "")
	reference := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = io.WriteString(w, `{"source":"reference"}`)
	}))
	defer reference.Close()
	t.Setenv("PITHEAD_DASHBOARD_REFERENCE_URL", reference.URL)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	file, err := listener.(*net.TCPListener).File()
	if err != nil {
		t.Fatal(err)
	}
	fd, err := syscall.Dup(int(file.Fd()))
	_ = file.Close()
	if err != nil {
		t.Fatal(err)
	}
	t.Setenv("PITHEAD_DASHBOARD_LISTEN_FD", strconv.Itoa(fd))
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	done := make(chan error, 1)
	go func() { done <- Run(ctx, io.Discard) }()
	client := &http.Client{Timeout: 5 * time.Second}
	for path, expected := range map[string]string{"/": "native-shell", "/api/state": `{"source":"reference"}`, "/api/config": "404: Not Found"} {
		response, err := client.Get("http://" + listener.Addr().String() + path)
		if err != nil {
			t.Fatal(err)
		}
		body, err := io.ReadAll(response.Body)
		_ = response.Body.Close()
		if err != nil || string(body) != expected || response.Header.Get("X-Frame-Options") != "DENY" {
			t.Fatalf("response %s: %q %v", path, body, err)
		}
	}
	cancel()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("dashboard did not drain after cancellation")
	}
}
