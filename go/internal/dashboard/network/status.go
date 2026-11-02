package network

import (
	"errors"
	"math"
	"math/big"
	"strconv"
)

const (
	stateEnforced   = "enforced"
	stateMissing    = "missing"
	stateUnverified = "unverified"
	maxNumericBits  = 1000
	maxEpoch        = 1 << 53
	maxStatusAge    = 360
)

const missingPrefix = "Tor-only egress firewall MISSING on the host (clearnet egress is not fail-closed; run 'pithead up')"
const unverifiedPrefix = "Egress firewall state unverified"

type numericValue struct {
	Kind  string  `json:"kind"`
	Value *string `json:"value,omitempty"`
}

type firewallPlan struct {
	Firewall bool   `json:"firewall"`
	Overlay  bool   `json:"overlay"`
	Warn     bool   `json:"warn"`
	Prefix   string `json:"prefix"`
}

func statusFieldsValid(rc, checked numericValue) (bool, error) {
	rcKind, _, _, err := parseNumeric(rc)
	if err != nil {
		return false, err
	}
	checkedKind, checkedInt, checkedFloat, err := parseNumeric(checked)
	if err != nil {
		return false, err
	}
	if rcKind != "int" || checkedKind == "invalid" {
		return false, nil
	}
	if checkedKind == "int" {
		limit := big.NewInt(maxEpoch)
		return checkedInt.Cmp(new(big.Int).Neg(limit)) >= 0 && checkedInt.Cmp(limit) <= 0, nil
	}
	return !math.IsNaN(checkedFloat) && !math.IsInf(checkedFloat, 0) && checkedFloat >= -maxEpoch && checkedFloat <= maxEpoch, nil
}

func firewallState(rc, age numericValue) (string, error) {
	rcKind, rcInt, _, err := parseNumeric(rc)
	if err != nil {
		return "", err
	}
	ageKind, ageInt, ageFloat, err := parseNumeric(age)
	if err != nil {
		return "", err
	}
	if rcKind != "int" || ageKind == "invalid" {
		return "", errors.New("invalid firewall status result input")
	}
	stale := false
	if ageKind == "int" {
		stale = ageInt.Cmp(big.NewInt(maxStatusAge)) > 0
	} else {
		stale = ageFloat > maxStatusAge
	}
	if stale {
		return stateUnverified, nil
	}
	if rcInt.Sign() == 0 {
		return stateEnforced, nil
	}
	for _, value := range []int64{1, 2, 4, 5} {
		if rcInt.Cmp(big.NewInt(value)) == 0 {
			return stateMissing, nil
		}
	}
	return stateUnverified, nil
}

func buildFirewallPlan(configured bool, state string) (firewallPlan, error) {
	if state != stateEnforced && state != stateMissing && state != stateUnverified {
		return firewallPlan{}, errors.New("invalid firewall state")
	}
	if !configured {
		return firewallPlan{}, nil
	}
	plan := firewallPlan{Firewall: state == stateEnforced, Overlay: true, Warn: state != stateEnforced}
	if state == stateMissing {
		plan.Prefix = missingPrefix
	} else if state == stateUnverified {
		plan.Prefix = unverifiedPrefix
	}
	return plan, nil
}

func parseNumeric(value numericValue) (string, *big.Int, float64, error) {
	if value.Kind == "invalid" {
		if value.Value != nil {
			return "", nil, 0, errors.New("invalid numeric metadata")
		}
		return value.Kind, nil, 0, nil
	}
	if value.Value == nil {
		return "", nil, 0, errors.New("missing numeric value")
	}
	switch value.Kind {
	case "int":
		parsed, ok := new(big.Int).SetString(*value.Value, 10)
		if !ok || parsed.String() != *value.Value || parsed.BitLen() > maxNumericBits {
			return "", nil, 0, errors.New("invalid integer metadata")
		}
		return value.Kind, parsed, 0, nil
	case "float":
		parsed, err := parseFloat(*value.Value)
		if err != nil {
			return "", nil, 0, err
		}
		return value.Kind, nil, parsed, nil
	default:
		return "", nil, 0, errors.New("invalid numeric kind")
	}
}

func parseFloat(value string) (float64, error) {
	switch value {
	case "nan":
		return math.NaN(), nil
	case "inf":
		return math.Inf(1), nil
	case "-inf":
		return math.Inf(-1), nil
	}
	parsed, err := strconv.ParseFloat(value, 64)
	if err != nil || math.IsNaN(parsed) || math.IsInf(parsed, 0) {
		return 0, errors.New("invalid float metadata")
	}
	return parsed, nil
}
