package nodeprobe

import (
	"bytes"
	"encoding/binary"
	"encoding/hex"
	"strings"
)

func ZMQGreetingOK(value string) (bool, error) {
	if err := validateZMQText(value); err != nil {
		return false, err
	}
	if len(value) != 128 {
		return false, nil
	}
	decoded, err := decodeZMQHex(value)
	if err != nil {
		return false, err
	}
	mechanism := append([]byte("NULL"), make([]byte, 16)...)
	return decoded[0] == 0xff &&
		decoded[9] == 0x7f &&
		decoded[10] >= 3 &&
		bytes.Equal(decoded[12:32], mechanism) &&
		allZero(decoded[32:64]), nil
}

func ZMQReadyIsPublisher(value string) (bool, error) {
	if err := validateZMQText(value); err != nil {
		return false, err
	}
	if len(value) < 4 {
		return false, nil
	}
	header, err := decodeZMQHex(value[:4])
	if err != nil {
		return false, err
	}
	flags, size := header[0], int(header[1])
	if flags&6 != 4 || size > 64 || len(value) != (size+2)*2 {
		return false, nil
	}
	decoded, err := decodeZMQHex(value)
	if err != nil {
		return false, err
	}
	body := decoded[2:]
	if !bytes.HasPrefix(body, []byte{5, 'R', 'E', 'A', 'D', 'Y'}) {
		return false, nil
	}
	for position := 6; position < size; {
		keySize := int(body[position])
		position++
		if position+keySize+4 > size {
			return false, nil
		}
		key := body[position : position+keySize]
		position += keySize
		valueSize := uint64(binary.BigEndian.Uint32(body[position : position+4]))
		position += 4
		if valueSize > uint64(size-position) {
			return false, nil
		}
		property := body[position : position+int(valueSize)]
		if bytes.Equal(key, []byte("Socket-Type")) {
			return bytes.Equal(property, []byte("PUB")) || bytes.Equal(property, []byte("XPUB")), nil
		}
		position += int(valueSize)
	}
	return false, nil
}

func ClassifyZMQPublisher(reply string, exitCode int) (string, error) {
	if strings.ContainsRune(reply, 0) {
		return "", ErrUnsupportedProbeInput
	}
	if exitCode != 0 {
		switch exitCode {
		case 2:
			return "protocol", nil
		case 124:
			return "timeout", nil
		default:
			return "refused", nil
		}
	}
	reply = strings.TrimRight(reply, "\n")
	greeting, ready := reply, reply
	if split := strings.IndexByte(reply, '\n'); split >= 0 {
		greeting, ready = reply[:split], reply[split+1:]
	}
	ok, err := ZMQGreetingOK(greeting)
	if err != nil {
		return "", err
	}
	if !ok {
		return "protocol", nil
	}
	ok, err = ZMQReadyIsPublisher(ready)
	if err != nil {
		return "", err
	}
	if !ok {
		return "protocol", nil
	}
	return "ok", nil
}

func decodeZMQHex(value string) ([]byte, error) {
	decoded, err := hex.DecodeString(value)
	if err != nil {
		return nil, ErrUnsupportedProbeInput
	}
	return decoded, nil
}

func validateZMQText(value string) error {
	for _, item := range []byte(value) {
		if item == 0 || item >= 0x80 {
			return ErrUnsupportedProbeInput
		}
	}
	return nil
}

func allZero(value []byte) bool {
	for _, item := range value {
		if item != 0 {
			return false
		}
	}
	return true
}
