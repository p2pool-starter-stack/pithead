package runtime

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	dashboardweb "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/web"
)

func Run(ctx context.Context, stderr io.Writer) error {
	root, err := webRoot()
	if err != nil {
		return err
	}
	listener, err := listen()
	if err != nil {
		return err
	}
	defer listener.Close()
	reference, err := startReference(root, stderr)
	if err != nil {
		return err
	}
	defer reference.close()
	server := &http.Server{
		Handler: dashboardweb.New(dashboardweb.Options{
			WebRoot: root, Reference: reference.handler,
			ControlEnabled: strings.EqualFold(strings.TrimSpace(os.Getenv("DASHBOARD_CONTROL_ENABLED")), "true"),
			PreviewEnabled: os.Getenv("DASHBOARD_UI_PREVIEW") == "1",
		}),
		ReadHeaderTimeout: 10 * time.Second,
	}
	served := make(chan error, 1)
	go func() { served <- server.Serve(listener) }()
	select {
	case <-ctx.Done():
	case <-reference.done:
		err = errors.New("dashboard reference backend exited")
	case serveErr := <-served:
		if !errors.Is(serveErr, http.ErrServerClosed) {
			err = serveErr
		}
	}
	drain, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if shutdownErr := server.Shutdown(drain); shutdownErr != nil {
		_ = server.Close()
		if err == nil {
			err = shutdownErr
		}
	}
	return err
}

func listen() (net.Listener, error) {
	if value := os.Getenv("PITHEAD_DASHBOARD_LISTEN_FD"); value != "" {
		fd, err := strconv.Atoi(value)
		if err != nil || fd < 3 {
			return nil, errors.New("invalid dashboard listener descriptor")
		}
		file := os.NewFile(uintptr(fd), "dashboard-listener")
		if file == nil {
			return nil, errors.New("invalid dashboard listener descriptor")
		}
		defer file.Close()
		return net.FileListener(file)
	}
	return net.Listen("tcp", "127.0.0.1:8000")
}

func webRoot() (string, error) {
	if root := os.Getenv("PITHEAD_DASHBOARD_WEB_ROOT"); root != "" {
		return filepath.Abs(root)
	}
	executable, err := os.Executable()
	if err != nil {
		return "", err
	}
	for _, root := range []string{
		filepath.Join(filepath.Dir(executable), "..", "..", "dashboard", "mining_dashboard", "web"),
		filepath.Join("mining_dashboard", "web"),
		filepath.Join("dashboard", "mining_dashboard", "web"),
	} {
		if info, statErr := os.Stat(filepath.Join(root, "templates", "index.html")); statErr == nil && info.Mode().IsRegular() {
			return filepath.Abs(root)
		}
	}
	return "", fmt.Errorf("dashboard web assets unavailable")
}
