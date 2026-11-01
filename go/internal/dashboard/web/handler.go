package web

import (
	"fmt"
	"io"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type Options struct {
	WebRoot        string
	ControlEnabled bool
	PreviewEnabled bool
	Reference      http.Handler
}

type handler struct {
	options    Options
	routes     []Route
	shellMu    sync.Mutex
	shell      []byte
	shellMTime time.Time
}

const contentSecurityPolicy = "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; frame-ancestors 'none'; base-uri 'self'; form-action 'self'"

func New(options Options) http.Handler {
	h := &handler{options: options, routes: Routes(options.ControlEnabled)}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		secured := &securityWriter{ResponseWriter: w}
		h.serveHTTP(secured, r)
		if !secured.wrote {
			secured.WriteHeader(http.StatusOK)
		}
	})
}

func (h *handler) serveHTTP(w http.ResponseWriter, r *http.Request) {
	methods, registered := h.methods(r.URL.Path)
	if !registered {
		writeError(w, http.StatusNotFound)
		return
	}
	if !methodAllowed(r.Method, methods) {
		w.Header().Set("Allow", strings.Join(methods, ","))
		writeError(w, http.StatusMethodNotAllowed)
		return
	}

	switch {
	case r.URL.Path == "/":
		h.serveTemplate(w, r, "index.html", "no-cache")
	case r.URL.Path == "/ui-preview":
		if !h.options.PreviewEnabled {
			writeError(w, http.StatusNotFound)
			return
		}
		h.serveFile(w, r, filepath.Join(h.options.WebRoot, "templates", "sovereign.html"), "text/html", "no-store")
	case r.URL.Path == "/static" || strings.HasPrefix(r.URL.Path, "/static/"):
		h.serveStatic(w, r)
	case h.options.Reference == nil:
		writeError(w, http.StatusServiceUnavailable)
	default:
		h.options.Reference.ServeHTTP(w, r)
	}
}

func (h *handler) methods(path string) ([]string, bool) {
	methods := make([]string, 0, 2)
	for _, route := range h.routes {
		match := route.Pattern == path
		if route.Pattern == "/static/{tail:.*}" {
			match = path == "/static" || strings.HasPrefix(path, "/static/")
		}
		if match {
			methods = append(methods, route.Method)
			if route.Method == http.MethodGet {
				methods = append(methods, http.MethodHead)
			}
		}
	}
	if len(methods) == 0 {
		return nil, false
	}
	sort.Strings(methods)
	return methods, true
}

func methodAllowed(method string, methods []string) bool {
	for _, allowed := range methods {
		if method == allowed {
			return true
		}
	}
	return false
}

func (h *handler) serveTemplate(w http.ResponseWriter, r *http.Request, name, cacheControl string) {
	path := filepath.Join(h.options.WebRoot, "templates", name)
	data := h.shellHTML(path)
	w.Header().Set("Content-Type", "text/html; charset=utf-8")
	w.Header().Set("Cache-Control", cacheControl)
	w.Header().Set("Content-Length", strconv.Itoa(len(data)))
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(data)
	}
}

func (h *handler) shellHTML(path string) []byte {
	h.shellMu.Lock()
	defer h.shellMu.Unlock()
	info, err := os.Stat(path)
	if err == nil && (h.shell == nil || info.ModTime().After(h.shellMTime)) {
		if data, readErr := os.ReadFile(path); readErr == nil && utf8.Valid(data) {
			text := strings.ReplaceAll(string(data), "\r\n", "\n")
			text = strings.ReplaceAll(text, "\r", "\n")
			h.shell = []byte(text)
			h.shellMTime = info.ModTime()
		}
	}
	if len(h.shell) == 0 {
		return []byte("<h1>Dashboard shell error</h1>")
	}
	return h.shell
}

func (h *handler) serveStatic(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path == "/static" || r.URL.Path == "/static/" {
		writeError(w, http.StatusForbidden)
		return
	}
	rel := strings.TrimPrefix(r.URL.Path, "/static/")
	if filepath.IsAbs(filepath.FromSlash(rel)) {
		writeError(w, http.StatusNotFound)
		return
	}
	root, err := filepath.EvalSymlinks(filepath.Join(h.options.WebRoot, "static"))
	if err != nil {
		writeError(w, http.StatusNotFound)
		return
	}
	path, err := resolvePath(root, rel)
	if err != nil || !within(root, path) {
		writeError(w, http.StatusNotFound)
		return
	}
	info, err := os.Stat(path)
	if os.IsNotExist(err) {
		writeStaticNotFound(w)
		return
	}
	if err != nil {
		writeError(w, http.StatusNotFound)
		return
	}
	if info.IsDir() {
		writeError(w, http.StatusForbidden)
		return
	}
	h.serveFile(w, r, path, contentType(path), "no-cache")
}

func writeStaticNotFound(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Transfer-Encoding", "chunked")
	w.WriteHeader(http.StatusNotFound)
}

func writeFileForbidden(w http.ResponseWriter) {
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Transfer-Encoding", "chunked")
	w.WriteHeader(http.StatusForbidden)
}

func within(root, path string) bool {
	rel, err := filepath.Rel(root, path)
	return err == nil && rel != ".." && !strings.HasPrefix(rel, ".."+string(filepath.Separator))
}

func resolvePath(root, relative string) (string, error) {
	path := root
	parts := strings.Split(filepath.FromSlash(relative), string(filepath.Separator))
	links := 0
	for len(parts) > 0 {
		part := parts[0]
		parts = parts[1:]
		switch part {
		case "", ".":
			continue
		case "..":
			path = filepath.Dir(path)
			continue
		}
		candidate := filepath.Join(path, part)
		info, err := os.Lstat(candidate)
		if os.IsNotExist(err) {
			path = candidate
			continue
		}
		if err != nil {
			return "", err
		}
		if info.Mode()&os.ModeSymlink == 0 {
			path = candidate
			continue
		}
		links++
		if links > 255 {
			return "", os.ErrInvalid
		}
		target, err := os.Readlink(candidate)
		if err != nil {
			return "", err
		}
		if filepath.IsAbs(target) {
			volume := filepath.VolumeName(target)
			path = volume + string(filepath.Separator)
			target = strings.TrimPrefix(target[len(volume):], string(filepath.Separator))
		} else {
			path = filepath.Dir(candidate)
		}
		parts = append(strings.Split(target, string(filepath.Separator)), parts...)
	}
	return path, nil
}

func (h *handler) serveFile(w http.ResponseWriter, r *http.Request, path, contentType, cacheControl string) {
	before, err := os.Stat(path)
	if err == nil && !before.Mode().IsRegular() {
		writeFileForbidden(w)
		return
	}
	if err != nil {
		writeError(w, http.StatusNotFound)
		return
	}
	file, err := openFile(path)
	if err != nil {
		writeError(w, http.StatusNotFound)
		return
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() {
		writeFileForbidden(w)
		return
	}
	w.Header().Set("Content-Type", contentType)
	w.Header().Set("Cache-Control", cacheControl)
	w.Header().Set("Etag", fmt.Sprintf("\"%x-%x\"", info.ModTime().UnixNano(), info.Size()))
	modTime := info.ModTime()
	if modTime.Nanosecond() != 0 {
		modTime = modTime.Truncate(time.Second).Add(time.Second)
	}
	http.ServeContent(&lastModifiedWriter{ResponseWriter: w, value: modTime.UTC().Format(http.TimeFormat)}, r, info.Name(), modTime, file)
}

func contentType(path string) string {
	switch strings.ToLower(filepath.Ext(path)) {
	case ".js", ".mjs":
		return "application/javascript"
	}
	if value := mime.TypeByExtension(filepath.Ext(path)); value != "" {
		return strings.TrimSuffix(value, "; charset=utf-8")
	}
	return "application/octet-stream"
}

func writeError(w http.ResponseWriter, status int) {
	text := strconv.Itoa(status) + ": " + http.StatusText(status)
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(text)))
	w.WriteHeader(status)
	_, _ = io.WriteString(w, text)
}

type securityWriter struct {
	http.ResponseWriter
	wrote bool
}

type lastModifiedWriter struct {
	http.ResponseWriter
	value string
}

func (w *lastModifiedWriter) WriteHeader(status int) {
	if status == http.StatusNotModified {
		w.Header().Set("Last-Modified", w.value)
	}
	w.ResponseWriter.WriteHeader(status)
}

func (w *lastModifiedWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func (w *securityWriter) Unwrap() http.ResponseWriter {
	return w.ResponseWriter
}

func (w *securityWriter) WriteHeader(status int) {
	if w.wrote {
		return
	}
	w.wrote = true
	applySecurityHeaders(w.Header())
	w.ResponseWriter.WriteHeader(status)
}

func (w *securityWriter) Write(data []byte) (int, error) {
	if !w.wrote {
		w.WriteHeader(http.StatusOK)
	}
	return w.ResponseWriter.Write(data)
}

func applySecurityHeaders(header http.Header) {
	header.Set("X-Content-Type-Options", "nosniff")
	header.Set("X-Frame-Options", "DENY")
	header.Set("Referrer-Policy", "no-referrer")
	header.Set("Content-Security-Policy", contentSecurityPolicy)
	if header.Get("Cache-Control") == "" {
		header.Set("Cache-Control", "no-cache")
	}
}
