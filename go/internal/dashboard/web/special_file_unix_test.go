//go:build darwin || linux

package web

import (
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"syscall"
	"testing"
	"time"
)

func TestSpecialFilesDoNotBlock(t *testing.T) {
	for _, target := range []string{"static/fifo", "templates/sovereign.html"} {
		t.Run(target, func(t *testing.T) {
			root := webRoot(t)
			path := filepath.Join(root, filepath.FromSlash(target))
			if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
				t.Fatal(err)
			}
			if err := syscall.Mkfifo(path, 0o600); err != nil {
				t.Fatal(err)
			}
			h := New(Options{WebRoot: root, PreviewEnabled: true})
			url := "/ui-preview"
			if target == "static/fifo" {
				url = "/static/fifo"
			}
			done := make(chan *httptest.ResponseRecorder, 1)
			go func() {
				done <- request(h, http.MethodGet, url, nil)
			}()
			select {
			case response := <-done:
				if response.Code != http.StatusForbidden || response.Body.Len() != 0 || response.Header().Get("Content-Type") != "application/octet-stream" || response.Header().Get("Transfer-Encoding") != "chunked" {
					t.Fatalf("special-file response = %d %q %#v", response.Code, response.Body.String(), response.Header())
				}
			case <-time.After(time.Second):
				t.Fatal("special-file request blocked")
			}
		})
	}
}
