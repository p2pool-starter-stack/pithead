package fleet

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"unicode/utf8"
)

const (
	configMetaWireLength = 65
	configMetaWireBytes  = 256
)

type configMetaPolicy struct {
	Revision     bool `json:"revision"`
	ChangedAt    bool `json:"changed_at"`
	Source       bool `json:"source"`
	LastChangeID bool `json:"last_change_id"`
}

func buildConfigMetaPolicy(request Request) (configMetaPolicy, error) {
	if len(request.Args) != 1 {
		return configMetaPolicy{}, errors.New("invalid fleet argument count")
	}
	var fields map[string]json.RawMessage
	if err := decodeConfigMetaValue(request.Args[0], &fields); err != nil {
		return configMetaPolicy{}, err
	}
	if len(fields) != 4 {
		return configMetaPolicy{}, errors.New("invalid config metadata fields")
	}
	values := make(map[string]any, 4)
	for _, name := range []string{"revision", "changed_at", "source", "last_change_id"} {
		raw, ok := fields[name]
		if !ok {
			return configMetaPolicy{}, errors.New("missing config metadata field")
		}
		value, err := decodeConfigMetaField(raw)
		if err != nil {
			return configMetaPolicy{}, err
		}
		values[name] = value
	}
	normalized := normalizeRigforgeConfigMeta(values)
	if normalized == nil {
		return configMetaPolicy{}, nil
	}
	meta := normalized.(map[string]any)
	return configMetaPolicy{
		Revision:     meta["revision"] != nil,
		ChangedAt:    meta["changed_at"] != nil,
		Source:       meta["source"] != nil,
		LastChangeID: meta["last_change_id"] != nil,
	}, nil
}

func decodeConfigMetaField(raw json.RawMessage) (any, error) {
	var fields map[string]json.RawMessage
	if err := decodeConfigMetaValue(raw, &fields); err != nil {
		return nil, err
	}
	var kind string
	kindRaw, ok := fields["kind"]
	if !ok || decodeConfigMetaValue(kindRaw, &kind) != nil {
		return nil, errors.New("invalid config metadata kind")
	}
	switch kind {
	case "other":
		if len(fields) != 1 {
			return nil, errors.New("invalid non-string config metadata")
		}
		return nil, nil
	case "string":
		if len(fields) < 2 || len(fields) > 3 {
			return nil, errors.New("invalid string config metadata")
		}
		var length *int
		if rawLength, ok := fields["length"]; !ok || decodeConfigMetaValue(rawLength, &length) != nil || length == nil || *length < 0 || *length > configMetaWireLength {
			return nil, errors.New("invalid config metadata length")
		}
		rawValue, hasValue := fields["value"]
		if *length == configMetaWireLength {
			if hasValue || len(fields) != 2 {
				return nil, errors.New("unexpected oversized config metadata value")
			}
			return nil, nil
		}
		if !hasValue {
			return nil, errors.New("missing config metadata value")
		}
		var value *string
		if decodeConfigMetaValue(rawValue, &value) != nil || value == nil || utf8.RuneCountInString(*value) != *length || len(*value) > configMetaWireBytes {
			return nil, errors.New("invalid config metadata value")
		}
		return *value, nil
	default:
		return nil, errors.New("invalid config metadata kind")
	}
}

func decodeConfigMetaValue(raw json.RawMessage, value any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		return errors.New("invalid config metadata value")
	}
	return nil
}
