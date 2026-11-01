package config

import (
	"errors"
	"testing"

	"github.com/p2pool-starter-stack/pithead/go/internal/host"
)

func TestApplianceSiteNames(t *testing.T) {
	candidates := []string{
		"box.local", "172.17.0.1", "8.8.8.8", "192.168.50.1", "192.168.50.2",
		"2001:db8::1", "fc00::1", "localhost", "localhost",
	}
	got, err := ApplianceSiteNames("box.local", " 172.17.0.1 ", "192.168.50", "false", candidates)
	want := "box.local 192.168.50.2 fc00::1 localhost"
	if err != nil || got != want {
		t.Fatalf("ApplianceSiteNames() = %q, %v; want %q, nil", got, err, want)
	}
}

func TestApplianceSiteNamesExposesPublic(t *testing.T) {
	got, err := ApplianceSiteNames("box", " ", "", "true", []string{"8.8.8.8", "2001:db8::1"})
	if err != nil || got != "box 8.8.8.8 2001:db8::1" {
		t.Fatalf("ApplianceSiteNames() = %q, %v", got, err)
	}
}

func TestApplianceSiteNamesPreservesWordDedupe(t *testing.T) {
	got, err := ApplianceSiteNames("one two", " ", "", "false", []string{"one", "two", "three"})
	if err != nil || got != "one two three" {
		t.Fatalf("ApplianceSiteNames() = %q, %v", got, err)
	}
}

func TestApplianceSiteNamesRejectsUnsupportedClassification(t *testing.T) {
	got, err := ApplianceSiteNames("box", " ", "", "false", []string{"10000000000002000::1"})
	if got != "" || !errors.Is(err, host.ErrUnsupportedIPInput) {
		t.Fatalf("ApplianceSiteNames() = %q, %v", got, err)
	}
}

func TestApplianceCertAltString(t *testing.T) {
	names := []string{"box.local", "192.168.1.2", "2001:db8::1", "123", "münchen.local"}
	want := "DNS:box.local,IP:192.168.1.2,IP:2001:db8::1,IP:123,DNS:münchen.local"
	if got := ApplianceCertAltString(names); got != want {
		t.Fatalf("ApplianceCertAltString() = %q; want %q", got, want)
	}
	if got := ApplianceCertAltString(nil); got != "" {
		t.Fatalf("ApplianceCertAltString(nil) = %q", got)
	}
}
