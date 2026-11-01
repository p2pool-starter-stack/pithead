package torhistory

import (
	"errors"
	"testing"
)

const outageA = "12345678-1234-4123-8123-123456789abc"
const outageB = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

func TestNext(t *testing.T) {
	tests := []struct {
		name       string
		old        string
		outage     string
		observedAt int64
		now        int64
		want       string
	}{
		{"first", `{}`, outageA, 1000, 1000, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1000}`},
		{"future boundary", `{}`, outageA, 1060, 1000, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1060}`},
		{"past boundary", `{}`, outageA, 700, 1000, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":700}`},
		{"duplicate", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1000}`, outageA, 1000, 1001, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1000}`},
		{"delayed", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1100}`, outageB, 1099, 1100, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1100}`},
		{"continuing", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1000}`, outageA, 1100, 1100, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1100}`},
		{"clock moved back", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1000}`, outageA, 1001, 950, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1001}`},
		{"second round", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1000,"rounds":1,"observed_at":1000}`, outageA, 1900, 1900, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1900,"rounds":2,"observed_at":1900}`},
		{"renewed window", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1900,"rounds":2,"observed_at":1900}`, outageA, 2800, 2800, `{"outage":"12345678-1234-4123-8123-123456789abc","first":1900,"last":2800,"rounds":2,"observed_at":2800}`},
		{"new outage", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1900,"rounds":2,"observed_at":1900}`, outageB, 1901, 1901, `{"outage":"aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa","first":1901,"last":1901,"rounds":1,"observed_at":1901}`},
		{"tombstone", `{"outage":"12345678-1234-4123-8123-123456789abc","first":1000,"last":1900,"rounds":2,"observed_at":1900}`, "", 1902, 1902, `{"outage":"","first":0,"last":0,"rounds":0,"observed_at":1902}`},
		{"delayed after tombstone", `{"outage":"","first":0,"last":0,"rounds":0,"observed_at":1902}`, outageA, 1901, 1902, `{"outage":"","first":0,"last":0,"rounds":0,"observed_at":1902}`},
		{"newer tombstone", `{"outage":"","first":0,"last":0,"rounds":0,"observed_at":1902}`, "", 1903, 1903, `{"outage":"","first":0,"last":0,"rounds":0,"observed_at":1903}`},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := Next([]byte(test.old), test.outage, test.observedAt, test.now)
			if err != nil || string(got) != test.want {
				t.Fatalf("Next() = %q, %v; want %q", got, err, test.want)
			}
		})
	}
}

func TestNextErrors(t *testing.T) {
	for _, test := range []struct {
		name       string
		old        string
		outage     string
		observedAt int64
		now        int64
		want       error
	}{
		{"future", `{}`, outageA, 1061, 1000, ErrStaleObservation},
		{"old", `{}`, outageA, 699, 1000, ErrStaleObservation},
		{"bad previous", `{"first":0}`, outageA, 1000, 1000, ErrUnsupportedInput},
		{"negative previous", `{"outage":"12345678-1234-4123-8123-123456789abc","first":-1,"last":0,"rounds":1,"observed_at":0}`, outageA, 1000, 1000, ErrUnsupportedInput},
		{"bad outage", `{}`, "A", 1000, 1000, ErrUnsupportedInput},
		{"unsafe observation", `{}`, outageA, maxSafeInteger + 1, maxSafeInteger, ErrUnsupportedInput},
		{"negative now", `{}`, outageA, 0, -1, ErrUnsupportedInput},
	} {
		t.Run(test.name, func(t *testing.T) {
			if _, err := Next([]byte(test.old), test.outage, test.observedAt, test.now); !errors.Is(err, test.want) {
				t.Fatalf("Next() error = %v; want %v", err, test.want)
			}
		})
	}
}

func TestNextRejectsNoncanonicalRecords(t *testing.T) {
	for _, old := range []string{
		` {}`,
		`{}\n\n`,
		`{"first":0,"outage":"","last":0,"rounds":0,"observed_at":0}`,
		`{"outage":"","first":00,"last":0,"rounds":0,"observed_at":0}`,
		`{"outage":"","first":0,"last":0,"rounds":0,"observed_at":0,"rounds":0}`,
		`{"outage":"","first":9007199254740992,"last":0,"rounds":0,"observed_at":0}`,
	} {
		if _, err := Next([]byte(old), "", 0, 0); !errors.Is(err, ErrUnsupportedInput) {
			t.Errorf("Next(%q) error = %v; want unsupported", old, err)
		}
	}
	if got, err := Next([]byte("{}\n"), outageA, 1, 1); err != nil || len(got) == 0 || got[len(got)-1] == '\n' {
		t.Fatalf("Next() persisted record = %q, %v", got, err)
	}
}

func TestValid(t *testing.T) {
	now := int64(100000)
	valid := `{"outage":"12345678-1234-4123-8123-123456789abc","first":96400,"last":98200,"rounds":2,"observed_at":100000}`
	tests := []struct {
		name   string
		record string
		now    int64
		want   bool
	}{
		{"valid", valid, now, true},
		{"persisted newline", valid + "\n", now, true},
		{"empty", `{}`, now, false},
		{"tombstone", `{"outage":"","first":0,"last":0,"rounds":0,"observed_at":100000}`, now, false},
		{"one round", `{"outage":"12345678-1234-4123-8123-123456789abc","first":96400,"last":98200,"rounds":1,"observed_at":100000}`, now, false},
		{"short rounds", `{"outage":"12345678-1234-4123-8123-123456789abc","first":99101,"last":100000,"rounds":2,"observed_at":100000}`, now, false},
		{"future last", `{"outage":"12345678-1234-4123-8123-123456789abc","first":98200,"last":100001,"rounds":2,"observed_at":100000}`, now, false},
		{"old window", `{"outage":"12345678-1234-4123-8123-123456789abc","first":13600,"last":98200,"rounds":2,"observed_at":100000}`, now, false},
		{"stale observation", `{"outage":"12345678-1234-4123-8123-123456789abc","first":96400,"last":98200,"rounds":2,"observed_at":96399}`, now, false},
		{"future observation boundary", `{"outage":"12345678-1234-4123-8123-123456789abc","first":96400,"last":98200,"rounds":2,"observed_at":100060}`, now, true},
		{"future observation", `{"outage":"12345678-1234-4123-8123-123456789abc","first":96400,"last":98200,"rounds":2,"observed_at":100061}`, now, false},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			got, err := Valid([]byte(test.record), test.now)
			if err != nil || got != test.want {
				t.Fatalf("Valid() = %v, %v; want %v", got, err, test.want)
			}
		})
	}
}

func TestValidRejectsUnsupportedInput(t *testing.T) {
	for _, value := range []string{"", `null`, `{"outage":"","first":0.0,"last":0,"rounds":0,"observed_at":0}`} {
		if _, err := Valid([]byte(value), 1000); !errors.Is(err, ErrUnsupportedInput) {
			t.Errorf("Valid(%q) error = %v; want unsupported", value, err)
		}
	}
	for _, value := range []string{
		`{"outage":"x","first":0,"last":0,"rounds":0,"observed_at":0}`,
		`{"outage":"12345678-1234-4123-8123-123456789abc","first":-1,"last":0,"rounds":2,"observed_at":0}`,
	} {
		if got, err := Valid([]byte(value), 1000); err != nil || got {
			t.Errorf("Valid(%q) = %v, %v; want false, nil", value, got, err)
		}
	}
}
