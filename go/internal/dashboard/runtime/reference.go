package runtime

import (
	"errors"
	"io"
	"net"
	"net/http"
	"net/http/httputil"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"syscall"
	"time"

	dashboardweb "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/web"
)

const referenceProgram = `import socket
from aiohttp import web
storage_installed = False
try:
    from mining_dashboard.service import storage_service
except ModuleNotFoundError as error:
    if error.name not in {"mining_dashboard.service", "mining_dashboard.service.storage_service"}:
        raise
else:
    from mining_dashboard.go_storage import install as install_storage
    install_storage()
    storage_installed = True
from mining_dashboard.main import SHUTDOWN_TIMEOUT, build_app
app = build_app()
if not storage_installed and "state_manager" in app:
    raise RuntimeError("native dashboard storage unavailable")
if "state_manager" in app and "latest_data" in app:
    try:
        from mining_dashboard.go_bridge import install
    except ModuleNotFoundError as error:
        if error.name != "mining_dashboard.go_bridge":
            raise
    else:
        install(app)
web.run_app(app, sock=socket.socket(fileno=3), print=None, shutdown_timeout=SHUTDOWN_TIMEOUT)
`

const referenceReadyTimeout = 30 * time.Second

type referenceBackend struct {
	handler http.Handler
	command *exec.Cmd
	done    chan struct{}
	inputs  dashboardweb.InputProvider
}

func startReference(webRoot string, stderr io.Writer) (*referenceBackend, error) {
	if raw := os.Getenv("PITHEAD_DASHBOARD_REFERENCE_URL"); raw != "" {
		return referenceProxy(raw, nil)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	defer listener.Close()
	file, err := listener.(*net.TCPListener).File()
	if err != nil {
		return nil, err
	}
	defer file.Close()
	directory := filepath.Dir(filepath.Dir(webRoot))
	python := os.Getenv("PITHEAD_DASHBOARD_PYTHON")
	if python == "" {
		python = filepath.Join(directory, ".venv", "bin", "python")
		if info, statErr := os.Stat(python); statErr != nil || !info.Mode().IsRegular() {
			python = "python3"
		}
	}
	command := exec.Command(python, "-c", referenceProgram)
	command.Dir = directory
	binary, err := os.Executable()
	if err != nil {
		return nil, err
	}
	command.Env = append(os.Environ(), "PITHEAD_IMPL=python", "PITHEAD_DASHBOARD_GO_BINARY="+binary)
	command.ExtraFiles = []*os.File{file}
	command.Stdout, command.Stderr = stderr, stderr
	if err := command.Start(); err != nil {
		return nil, errors.New("could not start dashboard reference backend")
	}
	backend, err := referenceProxy("http://"+listener.Addr().String(), command)
	if err != nil {
		_ = command.Process.Kill()
		_ = command.Wait()
		return nil, err
	}
	go func() {
		_ = command.Wait()
		close(backend.done)
	}()
	if err := waitReferenceReady("http://"+listener.Addr().String(), backend.done); err != nil {
		backend.close()
		return nil, err
	}
	return backend, nil
}

func waitReferenceReady(raw string, done <-chan struct{}) error {
	client := &http.Client{
		Timeout: 250 * time.Millisecond,
		Transport: &http.Transport{
			Proxy:             nil,
			DisableKeepAlives: true,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	defer client.CloseIdleConnections()
	deadline := time.NewTimer(referenceReadyTimeout)
	defer deadline.Stop()
	for {
		request, err := http.NewRequest(http.MethodGet, raw, nil)
		if err != nil {
			return err
		}
		response, err := client.Do(request)
		if err == nil {
			_ = response.Body.Close()
			return nil
		}
		select {
		case <-done:
			return errors.New("dashboard reference backend exited before becoming ready")
		case <-deadline.C:
			return errors.New("dashboard reference backend did not become ready")
		case <-time.After(25 * time.Millisecond):
		}
	}
}

func referenceProxy(raw string, command *exec.Cmd) (*referenceBackend, error) {
	target, err := url.Parse(raw)
	if err != nil || target.Scheme != "http" || target.Host == "" || target.User != nil || target.Path != "" || target.RawQuery != "" || target.Fragment != "" {
		return nil, errors.New("invalid dashboard reference URL")
	}
	if address := net.ParseIP(target.Hostname()); address == nil || !address.IsLoopback() {
		return nil, errors.New("dashboard reference must use a loopback address")
	}
	proxy := httputil.NewSingleHostReverseProxy(target)
	proxy.ErrorHandler = func(w http.ResponseWriter, r *http.Request, err error) {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.WriteHeader(http.StatusBadGateway)
		_, _ = io.WriteString(w, "502: Bad Gateway")
	}
	return &referenceBackend{handler: proxy, command: command, done: make(chan struct{}), inputs: inputProvider(target)}, nil
}

func (backend *referenceBackend) close() {
	if backend.command == nil {
		return
	}
	select {
	case <-backend.done:
		return
	default:
	}
	_ = backend.command.Process.Signal(syscall.SIGTERM)
	select {
	case <-backend.done:
	case <-time.After(5 * time.Second):
		_ = backend.command.Process.Kill()
		<-backend.done
	}
}
