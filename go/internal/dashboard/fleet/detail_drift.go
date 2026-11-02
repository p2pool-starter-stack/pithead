package fleet

import (
	"encoding/json"
	"errors"
	"math"
	"math/big"
	"reflect"
	"regexp"
	"sort"
	"strconv"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/controlhttp"
)

var canonicalNumber = map[string]bool{"DONATION": true, "watchdog_interval_min": true, "max_temp_c": true}
var canonicalString = map[string]bool{"autotune": true, "watchdog": true}
var decimalFloat = regexp.MustCompile(`^[+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?$`)

type comparableValue struct {
	tag   string
	value any
}

func buildConfigDrift(request Request) (any, error) {
	values, err := detailArguments(request, 3)
	if err != nil {
		return nil, err
	}
	unsettled, ok := values[2].(bool)
	if !ok {
		return nil, errors.New("expected unsettled boolean")
	}
	if err := validateDriftBounds(values[0], values[1], unsettled); err != nil {
		return nil, err
	}
	return configDrift(values[0], values[1], unsettled), nil
}

func configDrift(lastApplied, rigConfig any, unsettled bool) any {
	left, leftOK := lastApplied.(map[string]any)
	right, rightOK := rigConfig.(map[string]any)
	if unsettled || !leftOK || !rightOK {
		return nil
	}
	left = stripCredentials(left, 0).(map[string]any)
	right = stripCredentials(right, 0).(map[string]any)
	keys := make([]string, 0, len(left))
	for key := range left {
		keys = append(keys, key)
	}
	sort.Strings(keys)
	drift := make([]any, 0)
	for _, key := range keys {
		rig, present := right[key]
		if !present {
			continue
		}
		applied := left[key]
		if !comparableEqual(comparable(key, applied), comparable(key, rig)) {
			drift = append(drift, map[string]any{"key": key, "applied": applied, "rig": rig})
		}
	}
	return drift
}

func comparable(key string, value any) comparableValue {
	if _, ok := value.(bool); ok {
		return comparableValue{"raw", value}
	}
	if canonicalNumber[key] {
		if number, ok := pythonFloat(value); ok {
			return comparableValue{"num", number}
		}
		return comparableValue{"raw", value}
	}
	if canonicalString[key] {
		switch value := value.(type) {
		case string:
			return comparableValue{"str", value}
		case json.Number:
			return comparableValue{"str", pythonNumberString(value)}
		case float64:
			return comparableValue{"str", pythonFloatString(value)}
		}
	}
	return comparableValue{"raw", value}
}

func comparableEqual(left, right comparableValue) bool {
	return left.tag == right.tag && pythonEqual(left.value, right.value)
}

func pythonFloat(value any) (float64, bool) {
	switch value := value.(type) {
	case json.Number:
		number, err := value.Float64()
		return number, err == nil
	case float64:
		return value, true
	case string:
		number, err := parsePythonFloat(value)
		return number, err == nil
	default:
		return 0, false
	}
}

func pythonEqual(left, right any) bool {
	leftNumber, leftOK := dynamicNumber(left)
	rightNumber, rightOK := dynamicNumber(right)
	if leftOK && rightOK {
		if leftNumber.nan || rightNumber.nan {
			return false
		}
		if leftNumber.infinite != 0 || rightNumber.infinite != 0 {
			return leftNumber.infinite == rightNumber.infinite
		}
		return leftNumber.rat.Cmp(rightNumber.rat) == 0
	}
	leftMap, leftMapOK := left.(map[string]any)
	rightMap, rightMapOK := right.(map[string]any)
	if leftMapOK || rightMapOK {
		if !leftMapOK || !rightMapOK || len(leftMap) != len(rightMap) {
			return false
		}
		for key, value := range leftMap {
			other, ok := rightMap[key]
			if !ok || !pythonEqual(value, other) {
				return false
			}
		}
		return true
	}
	leftList, leftListOK := left.([]any)
	rightList, rightListOK := right.([]any)
	if leftListOK || rightListOK {
		if !leftListOK || !rightListOK || len(leftList) != len(rightList) {
			return false
		}
		for index := range leftList {
			if !pythonEqual(leftList[index], rightList[index]) {
				return false
			}
		}
		return true
	}
	return reflect.DeepEqual(left, right)
}

type dynamicNumeric struct {
	rat      *big.Rat
	infinite int
	nan      bool
}

func dynamicNumber(value any) (dynamicNumeric, bool) {
	switch value := value.(type) {
	case json.Number:
		if integer, ok := integerNumber(value); ok {
			return dynamicNumeric{rat: new(big.Rat).SetInt(integer)}, true
		}
		result, err := value.Float64()
		return floatNumeric(result, err)
	case float64:
		return floatNumeric(value, nil)
	case float32:
		return floatNumeric(float64(value), nil)
	case int:
		return dynamicNumeric{rat: new(big.Rat).SetInt64(int64(value))}, true
	case int64:
		return dynamicNumeric{rat: new(big.Rat).SetInt64(value)}, true
	case bool:
		if value {
			return dynamicNumeric{rat: big.NewRat(1, 1)}, true
		}
		return dynamicNumeric{rat: big.NewRat(0, 1)}, true
	default:
		return dynamicNumeric{}, false
	}
}

func floatNumeric(value float64, err error) (dynamicNumeric, bool) {
	if err != nil {
		return dynamicNumeric{}, false
	}
	if math.IsNaN(value) {
		return dynamicNumeric{nan: true}, true
	}
	if math.IsInf(value, 1) {
		return dynamicNumeric{infinite: 1}, true
	}
	if math.IsInf(value, -1) {
		return dynamicNumeric{infinite: -1}, true
	}
	return dynamicNumeric{rat: new(big.Rat).SetFloat64(value)}, true
}

func pythonNumberString(value json.Number) string {
	if integer, ok := integerNumber(value); ok {
		return integer.String()
	}
	number, err := value.Float64()
	if err != nil {
		return value.String()
	}
	return pythonFloatString(number)
}

func pythonFloatString(number float64) string {
	if math.IsNaN(number) {
		return "nan"
	}
	if math.IsInf(number, 1) {
		return "inf"
	}
	if math.IsInf(number, -1) {
		return "-inf"
	}
	format := byte('g')
	absolute := math.Abs(number)
	if absolute >= 1e-4 && absolute < 1e16 {
		format = 'f'
	}
	text := strconv.FormatFloat(number, format, -1, 64)
	if !math.IsInf(number, 0) && !math.IsNaN(number) {
		if _, err := strconv.ParseInt(text, 10, 64); err == nil {
			text += ".0"
		}
	}
	return text
}

func parsePythonFloat(value string) (float64, error) {
	value = strings.TrimSpace(value)
	switch {
	case strings.EqualFold(value, "inf"), strings.EqualFold(value, "+inf"), strings.EqualFold(value, "infinity"), strings.EqualFold(value, "+infinity"):
		return math.Inf(1), nil
	case strings.EqualFold(value, "-inf"), strings.EqualFold(value, "-infinity"):
		return math.Inf(-1), nil
	case strings.EqualFold(value, "nan"), strings.EqualFold(value, "+nan"), strings.EqualFold(value, "-nan"):
		return math.NaN(), nil
	}
	var normalized strings.Builder
	for _, current := range value {
		if digit, ok := controlhttp.PythonDecimalValue(current); ok {
			normalized.WriteByte(byte('0' + digit))
		} else {
			normalized.WriteRune(current)
		}
	}
	value = normalized.String()
	if strings.Contains(value, "_") {
		bytes := []byte(value)
		clean := make([]byte, 0, len(bytes))
		for index, current := range bytes {
			if current == '_' {
				if index == 0 || index+1 == len(bytes) || bytes[index-1] < '0' || bytes[index-1] > '9' || bytes[index+1] < '0' || bytes[index+1] > '9' {
					return 0, errors.New("invalid underscore")
				}
				continue
			}
			clean = append(clean, current)
		}
		value = string(clean)
	}
	if !decimalFloat.MatchString(value) {
		return 0, errors.New("invalid decimal float")
	}
	number, err := strconv.ParseFloat(value, 64)
	if errors.Is(err, strconv.ErrRange) {
		err = nil
	}
	return number, err
}

func stripCredentials(value any, depth int) any {
	if depth > 6 {
		return nil
	}
	switch value := value.(type) {
	case map[string]any:
		result := make(map[string]any, len(value))
		for key, item := range value {
			if key != "pass" && key != "tls-fingerprint" {
				result[key] = stripCredentials(item, depth+1)
			}
		}
		return result
	case []any:
		result := make([]any, len(value))
		for index, item := range value {
			result[index] = stripCredentials(item, depth+1)
		}
		return result
	default:
		return value
	}
}

func buildHasUnsettledApply(request Request) (any, error) {
	values, err := detailArguments(request, 1)
	if err != nil {
		return nil, err
	}
	if truthy(values[0]) {
		rows, err := array(values[0])
		if err != nil {
			return nil, err
		}
		for _, value := range rows {
			row, err := object(value)
			if err != nil {
				return nil, err
			}
			if member(row, "type", "apply") == "apply" {
				break
			}
		}
	}
	return hasUnsettledApply(values[0]), nil
}

func hasUnsettledApply(value any) bool {
	rows, ok := value.([]any)
	if !ok {
		return false
	}
	for _, value := range rows {
		row, ok := value.(map[string]any)
		if !ok || member(row, "type", "apply") != "apply" {
			continue
		}
		status := member(row, "status", nil)
		return status == "accepted" || status == "running"
	}
	return false
}

func buildConfigOrigin(request Request) (any, error) {
	values, err := detailArguments(request, 4)
	if err != nil {
		return nil, err
	}
	known, knownOK := values[1].(bool)
	unread, unreadOK := values[3].(bool)
	if !knownOK || !unreadOK {
		return nil, errors.New("expected origin booleans")
	}
	return configOrigin(values[0], known, values[2], unread), nil
}

func configOrigin(meta any, known bool, status any, unread bool) any {
	value, ok := meta.(map[string]any)
	if !ok || len(value) == 0 {
		return nil
	}
	switch member(value, "source", nil) {
	case "control":
		if unread {
			return "unread"
		}
		if !known {
			return "elsewhere"
		}
		if status == "applied" {
			return "here"
		}
		if status == "rolled_back" || status == "failed" || status == "rejected" {
			return "reverted"
		}
		return "unconfirmed"
	case "local":
		return "rig"
	case "restore":
		return "restored"
	default:
		return "unrecorded"
	}
}
