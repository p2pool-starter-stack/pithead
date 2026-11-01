package torhistory

import (
	"encoding/json"
	"errors"
	"regexp"
	"strconv"
)

var ErrUnsupportedInput = errors.New("unsupported Tor history input")
var ErrStaleObservation = errors.New("stale Tor history observation")

const maxSafeInteger int64 = 9007199254740991

var recordPattern = regexp.MustCompile(`^\{"outage":"([0-9A-Za-z-]*)","first":(-?(0|[1-9][0-9]*)),"last":(-?(0|[1-9][0-9]*)),"rounds":(-?(0|[1-9][0-9]*)),"observed_at":(-?(0|[1-9][0-9]*))\}$`)
var outagePattern = regexp.MustCompile(`^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$`)

type record struct {
	Outage     string `json:"outage"`
	First      int64  `json:"first"`
	Last       int64  `json:"last"`
	Rounds     int64  `json:"rounds"`
	ObservedAt int64  `json:"observed_at"`
}

func Next(previous []byte, outage string, observedAt, now int64) ([]byte, error) {
	old, empty, err := parse(previous)
	if err != nil || !empty && !nonnegative(old) || !validOutage(outage) || !safeInteger(observedAt) || !safeInteger(now) {
		return nil, ErrUnsupportedInput
	}
	if laterThan(observedAt, now, 60) || earlierThan(observedAt, now, 300) {
		return nil, ErrStaleObservation
	}
	oldObservedAt := int64(0)
	if !empty {
		oldObservedAt = old.ObservedAt
	}
	if observedAt < oldObservedAt || observedAt == oldObservedAt && outage != "" {
		return encode(old, empty)
	}
	if outage == "" {
		return encode(record{ObservedAt: observedAt}, false)
	}
	if empty || old.Outage != outage {
		return encode(record{Outage: outage, First: now, Last: now, Rounds: 1, ObservedAt: observedAt}, false)
	}
	if now >= old.Last && now-old.Last >= 900 {
		old.First = old.Last
		old.Last = now
		old.Rounds = 2
	}
	old.ObservedAt = observedAt
	return encode(old, false)
}

func Valid(data []byte, now int64) (bool, error) {
	value, empty, err := parse(data)
	if err != nil || !safeInteger(now) {
		return false, ErrUnsupportedInput
	}
	if empty || !outagePattern.MatchString(value.Outage) {
		return false, nil
	}
	if value.First < 0 || value.Last < 0 || value.Rounds < 0 || value.ObservedAt < 0 {
		return false, nil
	}
	if value.Rounds < 2 || value.First > value.Last || value.Last-value.First < 900 {
		return false, nil
	}
	if value.Last > now || now-value.First >= 86400 {
		return false, nil
	}
	if value.ObservedAt <= now && now-value.ObservedAt > 3600 {
		return false, nil
	}
	return !laterThan(value.ObservedAt, now, 60), nil
}

func parse(data []byte) (record, bool, error) {
	if len(data) > 0 && data[len(data)-1] == '\n' {
		data = data[:len(data)-1]
	}
	if string(data) == "{}" {
		return record{}, true, nil
	}
	parts := recordPattern.FindSubmatch(data)
	if parts == nil {
		return record{}, false, ErrUnsupportedInput
	}
	values := make([]int64, 4)
	for i := range values {
		part := parts[2+i*2]
		value, err := strconv.ParseInt(string(part), 10, 64)
		if err != nil || !exactInteger(value) || strconv.FormatInt(value, 10) != string(part) {
			return record{}, false, ErrUnsupportedInput
		}
		values[i] = value
	}
	return record{string(parts[1]), values[0], values[1], values[2], values[3]}, false, nil
}

func encode(value record, empty bool) ([]byte, error) {
	if empty {
		return []byte("{}"), nil
	}
	return json.Marshal(value)
}

func validOutage(value string) bool {
	return value == "" || outagePattern.MatchString(value)
}

func safeInteger(value int64) bool {
	return value >= 0 && value <= maxSafeInteger
}

func exactInteger(value int64) bool {
	return value >= -maxSafeInteger && value <= maxSafeInteger
}

func nonnegative(value record) bool {
	return value.First >= 0 && value.Last >= 0 && value.Rounds >= 0 && value.ObservedAt >= 0
}

func laterThan(value, base, distance int64) bool {
	return value > base && value-base > distance
}

func earlierThan(value, base, distance int64) bool {
	return value < base && base-value > distance
}
