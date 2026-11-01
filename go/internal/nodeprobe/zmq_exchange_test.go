package nodeprobe

import (
	"bytes"
	"errors"
	"io"
	"net"
	"testing"
	"time"
)

func TestExchangeZMQPublisherSuccess(t *testing.T) {
	greeting := exchangeGreeting()
	ready := exchangeReady("PUB")
	trailing := []byte("ignored")
	conn := &zmqScriptConn{
		reads:     append(append(greeting, ready...), trailing...),
		readSize:  1,
		writeSize: 2,
	}
	deadline := time.Unix(123, 456)

	got, err := ExchangeZMQPublisher(conn, deadline)
	if err != nil || got != "ok" {
		t.Fatalf("got %q, %v; want ok", got, err)
	}
	if conn.deadlineCalls != 1 || !conn.deadline.Equal(deadline) {
		t.Fatalf("deadline calls %d, value %v", conn.deadlineCalls, conn.deadline)
	}
	wantWrites := append(exchangeGreeting(), exchangeReady("SUB")...)
	if !bytes.Equal(conn.writes, wantWrites) {
		t.Fatalf("writes %x; want %x", conn.writes, wantWrites)
	}
	if !bytes.Equal(conn.reads[conn.readAt:], trailing) {
		t.Fatalf("remaining input %x; want %x", conn.reads[conn.readAt:], trailing)
	}
}

func TestExchangeZMQPublisherInputFailures(t *testing.T) {
	deadline := time.Unix(1, 0)
	if got, err := ExchangeZMQPublisher(nil, deadline); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("nil connection got %q, %v", got, err)
	}
	zeroDeadline := &zmqScriptConn{}
	if got, err := ExchangeZMQPublisher(zeroDeadline, time.Time{}); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("zero deadline got %q, %v", got, err)
	}
	if zeroDeadline.deadlineCalls != 0 || zeroDeadline.writeCalls != 0 || zeroDeadline.readAt != 0 {
		t.Fatalf("I/O occurred with zero deadline")
	}
	conn := &zmqScriptConn{deadlineErr: errors.New("unsupported")}
	if got, err := ExchangeZMQPublisher(conn, deadline); got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
		t.Fatalf("deadline failure got %q, %v", got, err)
	}
	if len(conn.writes) != 0 || conn.readAt != 0 {
		t.Fatalf("I/O occurred after deadline failure")
	}
}

func TestExchangeZMQPublisherGreetingBoundaries(t *testing.T) {
	valid := exchangeGreeting()
	tests := []struct {
		name    string
		reads   []byte
		readErr error
		want    string
	}{
		{"timeout", valid[:12], zmqTimeoutError{}, "timeout"},
		{"partial eof", valid[:63], io.EOF, "protocol"},
		{"full with eof", valid, io.EOF, "protocol"},
		{"invalid", append([]byte{0}, valid[1:]...), io.EOF, "protocol"},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			conn := &zmqScriptConn{reads: test.reads, readErr: test.readErr}
			got, err := ExchangeZMQPublisher(conn, time.Now())
			if err != nil || got != test.want {
				t.Fatalf("got %q, %v; want %q", got, err, test.want)
			}
			wantWrites := exchangeGreeting()
			if test.name == "full with eof" {
				wantWrites = append(wantWrites, exchangeReady("SUB")...)
			}
			if !bytes.Equal(conn.writes, wantWrites) {
				t.Fatalf("writes %x; want %x", conn.writes, wantWrites)
			}
		})
	}
}

func TestExchangeZMQPublisherReadyBoundaries(t *testing.T) {
	greeting := exchangeGreeting()
	pub := exchangeReady("PUB")
	oversized := append([]byte{4, 65}, make([]byte, 4)...)
	tests := []struct {
		name    string
		ready   []byte
		readErr error
		want    string
		remain  int
	}{
		{"header timeout", []byte{4}, zmqTimeoutError{}, "timeout", 0},
		{"short header eof", []byte{4}, io.EOF, "protocol", 0},
		{"long frame flag", append([]byte{6, 3}, 'P', 'U', 'B'), io.EOF, "protocol", 3},
		{"body timeout", oversized, zmqTimeoutError{}, "timeout", 0},
		{"partial body eof", pub[:len(pub)-1], io.EOF, "protocol", 0},
		{"invalid complete", exchangeReady("SUB"), io.EOF, "protocol", 0},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			conn := &zmqScriptConn{reads: append(append([]byte{}, greeting...), test.ready...), readErr: test.readErr}
			got, err := ExchangeZMQPublisher(conn, time.Now())
			if err != nil || got != test.want {
				t.Fatalf("got %q, %v; want %q", got, err, test.want)
			}
			if remaining := len(conn.reads) - conn.readAt; remaining != test.remain {
				t.Fatalf("remaining %d; want %d", remaining, test.remain)
			}
		})
	}
}

func TestExchangeZMQPublisherIgnoresWriteFailures(t *testing.T) {
	t.Run("first greeting write", func(t *testing.T) {
		conn := &zmqScriptConn{
			reads:       append(exchangeGreeting(), exchangeReady("XPUB")...),
			writeErrors: []error{errors.New("greeting failed")},
		}
		got, err := ExchangeZMQPublisher(conn, time.Now())
		if err != nil || got != "ok" {
			t.Fatalf("got %q, %v; want ok", got, err)
		}
		want := append(make([]byte, 48), exchangeReady("SUB")...)
		if conn.writeCalls != 3 || !bytes.Equal(conn.writes, want) {
			t.Fatalf("write calls %d, bytes %x; want 3, %x", conn.writeCalls, conn.writes, want)
		}
	})
	t.Run("ready timeout", func(t *testing.T) {
		conn := &zmqScriptConn{
			reads:       append(exchangeGreeting(), exchangeReady("PUB")...),
			writeErrors: []error{nil, nil, zmqTimeoutError{}},
		}
		got, err := ExchangeZMQPublisher(conn, time.Now())
		if err != nil || got != "ok" {
			t.Fatalf("got %q, %v; want ok", got, err)
		}
		if conn.writeCalls != 3 || !bytes.Equal(conn.writes, exchangeGreeting()) {
			t.Fatalf("write calls %d, bytes %x", conn.writeCalls, conn.writes)
		}
	})
}

func exchangeGreeting() []byte {
	value := make([]byte, 64)
	value[0] = 0xff
	value[9] = 0x7f
	value[10] = 3
	value[11] = 1
	copy(value[12:], "NULL")
	return value
}

func exchangeReady(socketType string) []byte {
	body := append([]byte{5, 'R', 'E', 'A', 'D', 'Y', 11}, []byte("Socket-Type")...)
	body = append(body, 0, 0, 0, byte(len(socketType)))
	body = append(body, socketType...)
	return append([]byte{4, byte(len(body))}, body...)
}

type zmqScriptConn struct {
	reads         []byte
	readAt        int
	readSize      int
	readErr       error
	writes        []byte
	writeSize     int
	writeCalls    int
	writeErrors   []error
	deadline      time.Time
	deadlineCalls int
	deadlineErr   error
}

func (conn *zmqScriptConn) Read(value []byte) (int, error) {
	if conn.readAt == len(conn.reads) {
		if conn.readErr != nil {
			return 0, conn.readErr
		}
		return 0, io.EOF
	}
	size := len(value)
	if conn.readSize > 0 && size > conn.readSize {
		size = conn.readSize
	}
	if remaining := len(conn.reads) - conn.readAt; size > remaining {
		size = remaining
	}
	n := copy(value, conn.reads[conn.readAt:conn.readAt+size])
	conn.readAt += n
	if conn.readAt == len(conn.reads) && conn.readErr != nil {
		return n, conn.readErr
	}
	return n, nil
}

func (conn *zmqScriptConn) Write(value []byte) (int, error) {
	call := conn.writeCalls
	conn.writeCalls++
	if call < len(conn.writeErrors) && conn.writeErrors[call] != nil {
		return 0, conn.writeErrors[call]
	}
	size := len(value)
	if conn.writeSize > 0 && size > conn.writeSize {
		size = conn.writeSize
	}
	conn.writes = append(conn.writes, value[:size]...)
	return size, nil
}

func (conn *zmqScriptConn) Close() error                     { return nil }
func (conn *zmqScriptConn) LocalAddr() net.Addr              { return zmqTestAddr("local") }
func (conn *zmqScriptConn) RemoteAddr() net.Addr             { return zmqTestAddr("remote") }
func (conn *zmqScriptConn) SetReadDeadline(time.Time) error  { return errors.New("unexpected") }
func (conn *zmqScriptConn) SetWriteDeadline(time.Time) error { return errors.New("unexpected") }
func (conn *zmqScriptConn) SetDeadline(value time.Time) error {
	conn.deadlineCalls++
	conn.deadline = value
	return conn.deadlineErr
}

type zmqTimeoutError struct{}

func (zmqTimeoutError) Error() string   { return "timeout" }
func (zmqTimeoutError) Timeout() bool   { return true }
func (zmqTimeoutError) Temporary() bool { return true }

type zmqTestAddr string

func (addr zmqTestAddr) Network() string { return string(addr) }
func (addr zmqTestAddr) String() string  { return string(addr) }
