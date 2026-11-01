package firewall

import (
	"errors"
	"testing"
)

func TestEgressUnquotedUnicodeFallback(t *testing.T) {
	line := "-A DOCKER-USER -s 10.0.0.0/8 -m comment\u2003-s 172.28.0.0/24 -j ACCEPT"
	if _, err := egressRuleShadows(line, "172.28.0.0/24"); !errors.Is(err, ErrUnsupportedInput) {
		t.Fatalf("locale-dependent whitespace: %v", err)
	}
	if tokens, ok, err := egressTokenise(`--comment "矿工 worker"`); err != nil || !ok || len(tokens) != 2 || tokens[1].Text != "矿工 worker" || !tokens[1].Quoted {
		t.Fatalf("quoted UTF-8: %#v, %t, %v", tokens, ok, err)
	}
}
