package controlhttp

import (
	"strconv"
	"strings"
	"unicode"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/wizard"
)

var python14DigitOnly = &unicode.RangeTable{
	R16: []unicode.Range16{
		{Lo: 0x00b2, Hi: 0x00b3, Stride: 1}, {Lo: 0x00b9, Hi: 0x00b9, Stride: 1},
		{Lo: 0x1369, Hi: 0x1371, Stride: 1}, {Lo: 0x19da, Hi: 0x19da, Stride: 1},
		{Lo: 0x2070, Hi: 0x2070, Stride: 1}, {Lo: 0x2074, Hi: 0x2079, Stride: 1},
		{Lo: 0x2080, Hi: 0x2089, Stride: 1}, {Lo: 0x2460, Hi: 0x2468, Stride: 1},
		{Lo: 0x2474, Hi: 0x247c, Stride: 1}, {Lo: 0x2488, Hi: 0x2490, Stride: 1},
		{Lo: 0x24ea, Hi: 0x24ea, Stride: 1}, {Lo: 0x24f5, Hi: 0x24fd, Stride: 1},
		{Lo: 0x24ff, Hi: 0x24ff, Stride: 1}, {Lo: 0x2776, Hi: 0x277e, Stride: 1},
		{Lo: 0x2780, Hi: 0x2788, Stride: 1}, {Lo: 0x278a, Hi: 0x2792, Stride: 1},
	},
	R32: []unicode.Range32{
		{Lo: 0x10a40, Hi: 0x10a43, Stride: 1}, {Lo: 0x10e60, Hi: 0x10e68, Stride: 1},
		{Lo: 0x11052, Hi: 0x1105a, Stride: 1}, {Lo: 0x1f100, Hi: 0x1f10a, Stride: 1},
	},
}

func workerDigitLimit(value *wizard.ConfigValue) (int, error) {
	if value == nil {
		return 4300, nil
	}
	if value.Kind != "int" {
		return 0, typeError("integer conversion limit must be an integer")
	}
	limit, err := strconv.Atoi(value.Text)
	if err != nil || limit < 0 {
		return 0, valueError("invalid integer conversion limit")
	}
	return limit, nil
}

func parseWorkerSemver(value string, maxDigits int) (*[3]string, error) {
	if value == "" {
		return nil, nil
	}
	core := strings.TrimFunc(value, func(current rune) bool {
		return unicode.IsSpace(current) || current >= 0x1c && current <= 0x1f
	})
	core = strings.TrimLeft(core, "vV")
	core, _, _ = strings.Cut(core, "-")
	core, _, _ = strings.Cut(core, "+")
	parts := strings.Split(core, ".")
	if len(parts) < 3 {
		return nil, nil
	}
	for index := 0; index < 3; index++ {
		if !pythonDigitString(parts[index]) {
			return nil, nil
		}
	}
	var parsed [3]string
	for index := range parsed {
		digits, err := pythonIntegerDigits(parts[index], maxDigits)
		if err != nil {
			return nil, err
		}
		parsed[index] = digits
	}
	return &parsed, nil
}

func pythonDigitString(value string) bool {
	if value == "" {
		return false
	}
	for _, current := range value {
		if !unicodeDigit(current) && !unicode.Is(python14DigitOnly, current) {
			return false
		}
	}
	return true
}

func pythonIntegerDigits(value string, maxDigits int) (string, error) {
	runes := []rune(value)
	if maxDigits > 0 && len(runes) > maxDigits {
		return "", valueError("integer string conversion exceeds the configured digit limit")
	}
	var normalized strings.Builder
	for _, current := range runes {
		digit, ok := pythonDecimalValue(current)
		if !ok {
			return "", valueError("invalid literal for int()")
		}
		normalized.WriteByte(byte('0' + digit))
	}
	result := strings.TrimLeft(normalized.String(), "0")
	if result == "" {
		result = "0"
	}
	return result, nil
}

func pythonDecimalValue(value rune) (int, bool) {
	for _, current := range python14Decimal.R16 {
		if value >= rune(current.Lo) && value <= rune(current.Hi) && (value-rune(current.Lo))%rune(current.Stride) == 0 {
			return int((value - rune(current.Lo)) / rune(current.Stride) % 10), true
		}
	}
	for _, current := range python14Decimal.R32 {
		if value >= rune(current.Lo) && value <= rune(current.Hi) && (value-rune(current.Lo))%rune(current.Stride) == 0 {
			return int((value - rune(current.Lo)) / rune(current.Stride) % 10), true
		}
	}
	return 0, false
}

func PythonDecimalValue(value rune) (int, bool) { return pythonDecimalValue(value) }
