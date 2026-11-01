//go:build parity && (darwin || linux)

package nodeprobe

import (
	"encoding/hex"
	"strconv"
	"testing"
)

func zmqExchangeReply(frame []byte) []byte {
	return append(zmqParityGreeting(), frame...)
}

func zmqExchangeFrame(t *testing.T, kind string) []byte {
	t.Helper()
	frame, err := hex.DecodeString(zmqParityFrame(zmqParityProperty("Socket-Type", kind)))
	if err != nil {
		t.Fatal(err)
	}
	return frame
}

func TestZMQExchangeParityFrames(t *testing.T) {
	for _, kind := range []string{"PUB", "XPUB", "SUB", "pub", "", "PUBLISHER"} {
		t.Run("type-"+kind, func(t *testing.T) {
			compareZMQExchange(t, zmqExchangeCase{reply: zmqExchangeReply(zmqExchangeFrame(t, kind))})
		})
	}
	t.Run("fragmented", func(t *testing.T) {
		compareZMQExchange(t, zmqExchangeCase{reply: zmqExchangeReply(zmqExchangeFrame(t, "PUB")), chunk: 1})
	})
	t.Run("ignored-trailing-frame", func(t *testing.T) {
		reply := zmqExchangeReply(zmqExchangeFrame(t, "PUB"))
		compareZMQExchange(t, zmqExchangeCase{reply: append(reply, []byte("ignored")...)})
	})
	for _, size := range []int{0, 1, 5, 6, 24, 25, 26, 64, 65, 255} {
		t.Run("declared-body-"+strconv.Itoa(size), func(t *testing.T) {
			frame := append([]byte{4, byte(size)}, make([]byte, size)...)
			compareZMQExchange(t, zmqExchangeCase{reply: zmqExchangeReply(frame)})
		})
	}
}

func TestZMQExchangeParityGreeting(t *testing.T) {
	for index := range 64 {
		t.Run("truncated-"+strconv.Itoa(index), func(t *testing.T) {
			compareZMQExchange(t, zmqExchangeCase{reply: zmqParityGreeting()[:index]})
		})
	}
	for index := range 64 {
		t.Run("changed-"+strconv.Itoa(index), func(t *testing.T) {
			greeting := zmqParityGreeting()
			greeting[index] ^= 0xff
			reply := append(greeting, zmqExchangeFrame(t, "PUB")...)
			compareZMQExchange(t, zmqExchangeCase{reply: reply})
		})
	}
}

func TestZMQExchangeParityHeaderFlags(t *testing.T) {
	for flags := range 256 {
		t.Run(strconv.Itoa(flags), func(t *testing.T) {
			frame := zmqExchangeFrame(t, "PUB")
			frame[0] = byte(flags)
			compareZMQExchange(t, zmqExchangeCase{reply: zmqExchangeReply(frame)})
		})
	}
}

func TestZMQExchangeParityReadyTruncation(t *testing.T) {
	frame := zmqExchangeFrame(t, "PUB")
	for index := range len(frame) {
		t.Run(strconv.Itoa(index), func(t *testing.T) {
			compareZMQExchange(t, zmqExchangeCase{reply: zmqExchangeReply(frame[:index])})
		})
	}
}

func TestZMQExchangeParityBlocking(t *testing.T) {
	for name, reply := range map[string][]byte{
		"silent-greeting":             nil,
		"partial-header":              zmqExchangeReply([]byte{4}),
		"oversized-body":              zmqExchangeReply([]byte{4, 65, 5, 'R', 'E', 'A', 'D', 'Y'}),
		"non-command-body":            zmqExchangeReply([]byte{0, 1}),
		"long-header-early-exit":      zmqExchangeReply([]byte{6, 255}),
		"invalid-greeting-early-exit": make([]byte, 64),
	} {
		t.Run(name, func(t *testing.T) {
			compareZMQExchange(t, zmqExchangeCase{reply: reply, holdOpen: true})
		})
	}
}
