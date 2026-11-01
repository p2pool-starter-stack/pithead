package nodeprobe

import (
	"encoding/hex"
	"errors"
	"io"
	"net"
	"time"
)

const zmqClientGreeting = "\xff\x00\x00\x00\x00\x00\x00\x00\x00\x7f\x03\x01NULL" +
	"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" +
	"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00" +
	"\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00"

const zmqClientReady = "\x04\x19\x05READY\x0bSocket-Type\x00\x00\x00\x03SUB"

func ExchangeZMQPublisher(conn net.Conn, deadline time.Time) (string, error) {
	if conn == nil || deadline.IsZero() {
		return "", ErrUnsupportedProbeInput
	}
	if err := conn.SetDeadline(deadline); err != nil {
		return "", ErrUnsupportedProbeInput
	}

	writeZMQBytes(conn, zmqClientGreeting[:16])
	writeZMQBytes(conn, zmqClientGreeting[16:])
	greeting := make([]byte, 64)
	n, err := io.ReadFull(conn, greeting)
	if isZMQTimeout(err) {
		return "timeout", nil
	}
	greetingHex := hex.EncodeToString(greeting[:n])
	ok, validationErr := ZMQGreetingOK(greetingHex)
	if validationErr != nil {
		return "", validationErr
	}
	if !ok {
		return "protocol", nil
	}

	writeZMQBytes(conn, zmqClientReady)
	header := make([]byte, 2)
	n, err = io.ReadFull(conn, header)
	if isZMQTimeout(err) {
		return "timeout", nil
	}
	if n != len(header) || header[0]&2 != 0 {
		return "protocol", nil
	}

	var body [255]byte
	n, err = io.ReadFull(conn, body[:int(header[1])])
	if isZMQTimeout(err) {
		return "timeout", nil
	}
	ready := hex.EncodeToString(append(header, body[:n]...))
	return ClassifyZMQPublisher(greetingHex+"\n"+ready, 0)
}

func writeZMQBytes(conn net.Conn, value string) {
	for len(value) > 0 {
		n, err := conn.Write([]byte(value))
		if n > 0 {
			value = value[n:]
		}
		if err != nil || n == 0 {
			return
		}
	}
}

func isZMQTimeout(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}
