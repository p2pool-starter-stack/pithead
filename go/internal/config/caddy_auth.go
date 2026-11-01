package config

import (
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"errors"
	"strings"
)

var ErrUnsupportedCaddyAuth = errors.New("unsupported Caddy auth preparation")

func CaddyAuthBlock(user, encodedHash string) (string, error) {
	if encodedHash == "" {
		return "", nil
	}
	decoded, err := base64.StdEncoding.DecodeString(encodedHash)
	if err != nil || base64.StdEncoding.EncodeToString(decoded) != encodedHash {
		return "", ErrUnsupportedCaddyAuth
	}
	hash := strings.TrimRight(string(decoded), "\n")
	if strings.IndexByte(hash, 0) >= 0 {
		return "", ErrUnsupportedCaddyAuth
	}
	return "    basic_auth {\n        " + user + " " + hash + "\n    }", nil
}

func CaddyBootCapability(encodedHash string) string {
	sum := sha256.Sum256([]byte("pithead-boot-health-v1:" + encodedHash))
	return hex.EncodeToString(sum[:])
}
