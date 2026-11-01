//go:build parity

package nodeprobe

import (
	"encoding/hex"
	"fmt"
	"strings"
	"testing"
)

func TestZMQParityGreeting(t *testing.T) {
	for position := 0; position < 64; position++ {
		t.Run(fmt.Sprintf("byte-%d", position), func(t *testing.T) {
			greeting := zmqParityGreeting()
			greeting[position] ^= 1
			compareZMQ(t, "greeting", hex.EncodeToString(greeting), 0)
		})
	}
	for _, major := range []byte{0, 2, 3, 4, 255} {
		t.Run(fmt.Sprintf("major-%d", major), func(t *testing.T) {
			greeting := zmqParityGreeting()
			greeting[10] = major
			compareZMQ(t, "greeting", hex.EncodeToString(greeting), 0)
		})
	}
	greeting := hex.EncodeToString(zmqParityGreeting())
	for name, value := range map[string]string{"valid": greeting, "upper": strings.ToUpper(greeting), "empty": "", "short": greeting[:126], "odd": greeting[:127], "long": greeting + "00"} {
		t.Run(name, func(t *testing.T) { compareZMQ(t, "greeting", value, 0) })
	}
}

func TestZMQParityFlags(t *testing.T) {
	frame := zmqParityFrame(zmqParityProperty("Socket-Type", "PUB"))
	for flags := 0; flags < 256; flags++ {
		t.Run(fmt.Sprintf("%02x", flags), func(t *testing.T) {
			compareZMQ(t, "ready", fmt.Sprintf("%02x", flags)+frame[2:], 0)
		})
	}
}

func TestZMQParityMetadata(t *testing.T) {
	pub := zmqParityProperty("Socket-Type", "PUB")
	sub := zmqParityProperty("Socket-Type", "SUB")
	for name, properties := range map[string][][]byte{
		"pub": {pub}, "xpub": {zmqParityProperty("Socket-Type", "XPUB")}, "sub": {sub},
		"lower-value": {zmqParityProperty("Socket-Type", "pub")}, "empty-value": {zmqParityProperty("Socket-Type", "")},
		"lower-key": {zmqParityProperty("socket-type", "PUB")}, "unknown": {zmqParityProperty("Other", "PUB")},
		"unknown-first": {zmqParityProperty("Other", "\x00\xff"), pub},
		"empty-first":   {zmqParityProperty("", ""), pub}, "no-properties": {},
		"first-pub": {pub, sub}, "first-sub": {sub, pub},
		"ignored-malformed-tail": {pub, {0xff}}, "truncated-key": {{11, 'S', 'o'}},
		"truncated-value-size": {{1, 'K', 0, 0}},
		"truncated-value":      {{1, 'K', 0, 0, 0, 3, 'P', 'U'}},
		"huge-value":           {{1, 'K', 0xff, 0xff, 0xff, 0xff}},
		"cap-exact":            {pub, []byte(strings.Repeat("\x00", 39))},
		"cap-over":             {pub, []byte(strings.Repeat("\x00", 40))},
	} {
		t.Run(name, func(t *testing.T) { compareZMQ(t, "ready", zmqParityFrame(properties...), 0) })
	}
	frame := zmqParityFrame(pub)
	for name, value := range map[string]string{
		"uppercase": strings.ToUpper(frame), "wrong-ready": frame[:6] + "7265616479" + frame[16:],
		"extra-byte": frame + "00", "missing-byte": frame[:len(frame)-2], "odd": frame + "0",
		"short": "04", "size-zero": "0400", "header-long": "06" + frame[2:],
	} {
		t.Run(name, func(t *testing.T) { compareZMQ(t, "ready", value, 0) })
	}
}

func TestZMQParityTruncation(t *testing.T) {
	frame := zmqParityFrame(zmqParityProperty("Socket-Type", "PUB"))
	for length := 0; length < len(frame); length++ {
		t.Run(fmt.Sprintf("%d", length), func(t *testing.T) {
			compareZMQ(t, "ready", frame[:length], 0)
		})
	}
}

func TestZMQParityClassifications(t *testing.T) {
	greeting := hex.EncodeToString(zmqParityGreeting())
	pub := zmqParityFrame(zmqParityProperty("Socket-Type", "PUB"))
	for _, code := range []int{0, 2, 124, 1, 7, 28, 127, 130} {
		for _, complete := range []bool{false, true} {
			t.Run(fmt.Sprintf("%d/%t", code, complete), func(t *testing.T) {
				reply := greeting
				if complete {
					reply += "\n" + pub
				}
				compareZMQ(t, "classify", reply, code)
			})
		}
	}
	for name, reply := range map[string]string{
		"empty": "", "trailing-lines": greeting + "\n" + pub + "\n\n",
		"extra-lines": greeting + "\n" + pub + "\nextra",
		"sub":         greeting + "\n" + zmqParityFrame(zmqParityProperty("Socket-Type", "SUB")),
		"xpub":        greeting + "\n" + zmqParityFrame(zmqParityProperty("Socket-Type", "XPUB")),
		"upper":       strings.ToUpper(greeting + "\n" + pub), "empty-greeting": "\n" + pub,
		"bad-greeting": "00" + greeting[2:] + "\n" + pub, "cr-greeting": greeting + "\r\n" + pub,
	} {
		t.Run(name, func(t *testing.T) { compareZMQ(t, "classify", reply, 0) })
	}
}
