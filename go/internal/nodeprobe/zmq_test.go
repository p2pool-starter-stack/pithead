package nodeprobe

import (
	"encoding/binary"
	"encoding/hex"
	"errors"
	"strings"
	"testing"
)

func TestZMQGreetingOK(t *testing.T) {
	valid := zmqGreeting()
	tests := []struct {
		name        string
		value       string
		want        bool
		unsupported bool
	}{
		{"valid", valid, true, false},
		{"uppercase", strings.ToUpper(valid), true, false},
		{"ignored signature", replaceHexByte(valid, 4, 0xab), true, false},
		{"ignored minor", replaceHexByte(valid, 11, 0xff), true, false},
		{"newer major", replaceHexByte(valid, 10, 0xfe), true, false},
		{"old major", replaceHexByte(valid, 10, 2), false, false},
		{"wrong first byte", replaceHexByte(valid, 0, 0xfe), false, false},
		{"wrong signature end", replaceHexByte(valid, 9, 0x7e), false, false},
		{"wrong mechanism", replaceHexByte(valid, 12, 'X'), false, false},
		{"mechanism padding", replaceHexByte(valid, 31, 1), false, false},
		{"tail padding", replaceHexByte(valid, 63, 1), false, false},
		{"short", valid[:126], false, false},
		{"long", valid + "00", false, false},
		{"non-ascii short", "é", false, true},
		{"nonhex", "z" + valid[1:], false, true},
		{"invalid utf8", string(append([]byte{0xff}, []byte(valid[1:])...)), false, true},
		{"nul", strings.Repeat("0", 127) + "\x00", false, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ZMQGreetingOK(test.value)
			assertZMQResult(t, got, err, test.want, test.unsupported)
		})
	}
}

func TestZMQReadyIsPublisher(t *testing.T) {
	pub := zmqReady(4, zmqProperty("Socket-Type", "PUB"))
	tests := []struct {
		name        string
		value       string
		want        bool
		unsupported bool
	}{
		{"pub", pub, true, false},
		{"xpub", zmqReady(4, zmqProperty("Socket-Type", "XPUB")), true, false},
		{"uppercase hex", strings.ToUpper(pub), true, false},
		{"more flag", zmqReady(5, zmqProperty("Socket-Type", "PUB")), true, false},
		{"other flag bits", zmqReady(0xfd, zmqProperty("Socket-Type", "PUB")), true, false},
		{"long frame flag", zmqReady(6, zmqProperty("Socket-Type", "PUB")), false, false},
		{"sub", zmqReady(4, zmqProperty("Socket-Type", "SUB")), false, false},
		{"case sensitive key", zmqReady(4, zmqProperty("socket-type", "PUB")), false, false},
		{"case sensitive value", zmqReady(4, zmqProperty("Socket-Type", "pub")), false, false},
		{"unknown then pub", zmqReady(4, append(zmqProperty("Other", "value"), zmqProperty("Socket-Type", "PUB")...)), true, false},
		{"empty unknown then pub", zmqReady(4, append(zmqProperty("", ""), zmqProperty("Socket-Type", "PUB")...)), true, false},
		{"first socket wins false", zmqReady(4, append(zmqProperty("Socket-Type", "SUB"), zmqProperty("Socket-Type", "PUB")...)), false, false},
		{"first socket wins true", zmqReady(4, append(zmqProperty("Socket-Type", "PUB"), []byte{20}...)), true, false},
		{"no socket", zmqReady(4, zmqProperty("Other", "PUB")), false, false},
		{"command only", zmqReady(4, nil), false, false},
		{"wrong command", replaceHexByte(zmqReady(4, nil), 3, 'X'), false, false},
		{"truncated key", rawZMQReady(4, append([]byte{5, 'R', 'E', 'A', 'D', 'Y', 2}, 'A')), false, false},
		{"truncated value length", rawZMQReady(4, append([]byte{5, 'R', 'E', 'A', 'D', 'Y', 1, 'A'}, 0, 0)), false, false},
		{"oversized value", rawZMQReady(4, append(append([]byte{5, 'R', 'E', 'A', 'D', 'Y'}, zmqPropertyHeader("A", 2)...), 'x')), false, false},
		{"declared size mismatch", replaceHexByte(pub, 1, 1), false, false},
		{"size over limit", rawZMQReady(4, make([]byte, 65)), false, false},
		{"long body rejected by declared size", "0406" + strings.Repeat("00", 4096), false, false},
		{"short", "04", false, false},
		{"odd", "041", false, false},
		{"odd canonical hex", "0412f", false, false},
		{"odd nonhex", "gg000", false, true},
		{"non-ascii short", "é", false, true},
		{"nonhex", "04zz", false, true},
		{"nul", "04\x00", false, true},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ZMQReadyIsPublisher(test.value)
			assertZMQResult(t, got, err, test.want, test.unsupported)
		})
	}
}

func TestClassifyZMQPublisher(t *testing.T) {
	greeting := zmqGreeting()
	ready := zmqReady(4, zmqProperty("Socket-Type", "PUB"))
	tests := []struct {
		name        string
		reply       string
		exitCode    int
		want        string
		unsupported bool
	}{
		{"publisher", greeting + "\n" + ready, 0, "ok", false},
		{"trailing newlines", greeting + "\n" + ready + "\n\n", 0, "ok", false},
		{"no newline", greeting, 0, "protocol", false},
		{"bad greeting", strings.Repeat("0", 128) + "\n" + ready, 0, "protocol", false},
		{"bad ready", greeting + "\n" + zmqReady(4, zmqProperty("Socket-Type", "SUB")), 0, "protocol", false},
		{"first newline", greeting + "\n" + ready + "\nextra", 0, "protocol", false},
		{"protocol exit", "invalid", 2, "protocol", false},
		{"timeout", "invalid", 124, "timeout", false},
		{"refused", "invalid", 1, "refused", false},
		{"other exit", string([]byte{0xff}), 9, "refused", false},
		{"nul before exit", "bad\x00", 124, "", true},
		{"unsupported greeting", "z" + greeting[1:] + "\n" + ready, 0, "", true},
		{"short circuit ready", strings.Repeat("0", 128) + "\nzz", 0, "protocol", false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := ClassifyZMQPublisher(test.reply, test.exitCode)
			if test.unsupported {
				if got != "" || !errors.Is(err, ErrUnsupportedProbeInput) {
					t.Fatalf("got %q, %v", got, err)
				}
				return
			}
			if err != nil || got != test.want {
				t.Fatalf("got %q, %v; want %q", got, err, test.want)
			}
		})
	}
}

func zmqGreeting() string {
	value := make([]byte, 64)
	value[0] = 0xff
	value[9] = 0x7f
	value[10] = 3
	value[11] = 1
	copy(value[12:32], []byte("NULL"))
	return hex.EncodeToString(value)
}

func zmqReady(flags byte, properties []byte) string {
	body := append([]byte{5, 'R', 'E', 'A', 'D', 'Y'}, properties...)
	return rawZMQReady(flags, body)
}

func rawZMQReady(flags byte, body []byte) string {
	return hex.EncodeToString(append([]byte{flags, byte(len(body))}, body...))
}

func zmqProperty(key, value string) []byte {
	return append(zmqPropertyHeader(key, uint32(len(value))), value...)
}

func zmqPropertyHeader(key string, valueSize uint32) []byte {
	result := append([]byte{byte(len(key))}, key...)
	encoded := make([]byte, 4)
	binary.BigEndian.PutUint32(encoded, valueSize)
	return append(result, encoded...)
}

func replaceHexByte(value string, offset int, replacement byte) string {
	decoded, _ := hex.DecodeString(value)
	decoded[offset] = replacement
	return hex.EncodeToString(decoded)
}

func assertZMQResult(t *testing.T, got bool, err error, want, unsupported bool) {
	t.Helper()
	if unsupported {
		if got || !errors.Is(err, ErrUnsupportedProbeInput) {
			t.Fatalf("got %t, %v", got, err)
		}
		return
	}
	if err != nil || got != want {
		t.Fatalf("got %t, %v; want %t", got, err, want)
	}
}
