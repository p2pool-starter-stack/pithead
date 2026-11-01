//go:build parity && (darwin || linux)

package nodeprobe

import (
	"bytes"
	"context"
	"errors"
	"io"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"syscall"
	"testing"
	"time"
)

type zmqExchangeCase struct {
	reply    []byte
	holdOpen bool
	chunk    int
}

type zmqExchangePeer struct {
	wire []byte
	err  error
}

func zmqExchangePair(t *testing.T) (*os.File, *net.UnixConn) {
	t.Helper()
	pair, err := syscall.Socketpair(syscall.AF_UNIX, syscall.SOCK_STREAM, 0)
	if err != nil {
		t.Fatal(err)
	}
	client, server := os.NewFile(uintptr(pair[0]), "zmq-client"), os.NewFile(uintptr(pair[1]), "zmq-peer")
	connection, err := net.FileConn(server)
	server.Close()
	if err != nil {
		client.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { client.Close(); connection.Close() })
	return client, connection.(*net.UnixConn)
}

func serveZMQExchange(peer *net.UnixConn, test zmqExchangeCase, finished <-chan struct{}) <-chan zmqExchangePeer {
	result := make(chan zmqExchangePeer, 1)
	go func() {
		defer peer.Close()
		peer.SetDeadline(time.Now().Add(8 * time.Second))
		greeting := make([]byte, 64)
		n, err := io.ReadFull(peer, greeting)
		if err != nil {
			result <- zmqExchangePeer{greeting[:n], err}
			return
		}
		greetingSize := min(64, len(test.reply))
		write := func(value []byte) error {
			for len(value) > 0 {
				count := len(value)
				if test.chunk > 0 {
					count = min(count, test.chunk)
				}
				if _, err := peer.Write(value[:count]); err != nil {
					return err
				}
				value = value[count:]
			}
			return nil
		}
		if err = write(test.reply[:greetingSize]); err != nil {
			result <- zmqExchangePeer{greeting, err}
			return
		}
		if greetingSize == 64 {
			ready := make([]byte, 27)
			n, err = io.ReadFull(peer, ready)
			greeting = append(greeting, ready[:n]...)
			if err != nil {
				if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
					err = nil
				}
				result <- zmqExchangePeer{greeting, err}
				return
			}
			if err = write(test.reply[64:]); err != nil {
				result <- zmqExchangePeer{greeting, err}
				return
			}
		}
		if test.holdOpen {
			<-finished
		}
		peer.CloseWrite()
		tail, err := io.ReadAll(peer)
		if errors.Is(err, syscall.ECONNRESET) {
			err = nil
		}
		result <- zmqExchangePeer{append(greeting, tail...), err}
	}()
	return result
}

func zmqExchangeReference(t *testing.T, test zmqExchangeCase) (string, []byte) {
	t.Helper()
	if parityBash == "" {
		t.Fatal("Bash is required")
	}
	timeout, err := exec.LookPath("timeout")
	if err != nil {
		t.Fatal("GNU timeout is required")
	}
	dir := t.TempDir()
	for _, tool := range []string{"head", "od", "tr"} {
		program := tool
		if tool == "head" && runtime.GOOS == "darwin" {
			program = "ghead"
		}
		path, err := exec.LookPath(program)
		if err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(path, filepath.Join(dir, tool)); err != nil {
			t.Fatal(err)
		}
	}
	client, peer := zmqExchangePair(t)
	finished := make(chan struct{})
	result := serveZMQExchange(peer, test, finished)
	_, file, _, _ := runtime.Caller(0)
	root := filepath.Clean(filepath.Join(filepath.Dir(file), "..", "..", ".."))
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, parityBash, filepath.Join(root, "tests/go-parity/node_zmq_exchange_reference.sh"), root)
	cmd.ExtraFiles = []*os.File{client}
	cmd.Env = []string{"PATH=" + dir, "LC_ALL=C", "TMPDIR=" + t.TempDir(), "ZMQ_TIMEOUT=" + timeout, "ZMQ_BASH=" + parityBash}
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	err = cmd.Run()
	client.Close()
	close(finished)
	observation := <-result
	if err != nil || stderr.Len() != 0 || observation.err != nil {
		t.Fatalf("Bash stream oracle failed: process=%v diagnostic=%q peer=%v", err, stderr.String(), observation.err)
	}
	return stdout.String(), observation.wire
}

func compareZMQExchange(t *testing.T, test zmqExchangeCase) {
	t.Helper()
	want, wantWire := zmqExchangeReference(t, test)
	client, peer := zmqExchangePair(t)
	connection, err := net.FileConn(client)
	client.Close()
	if err != nil {
		t.Fatal(err)
	}
	finished := make(chan struct{})
	result := serveZMQExchange(peer, test, finished)
	reason, err := ExchangeZMQPublisher(connection, time.Now().Add(5*time.Second))
	connection.Close()
	close(finished)
	observation := <-result
	if err != nil || observation.err != nil {
		t.Fatalf("Go stream exchange failed: %v, peer=%v", err, observation.err)
	}
	got := "1\n" + reason + "\n"
	if reason == "ok" {
		got = "0\nok\n"
	}
	if got != want || !bytes.Equal(observation.wire, wantWire) {
		t.Fatalf("stream result or client bytes differ: Go=%q Bash=%q, bytes=%d/%d", got, want, len(observation.wire), len(wantWire))
	}
}
