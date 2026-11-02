package wizard

import (
	"fmt"
	"math/big"
	"strconv"
	"strings"
	"unicode"
	"unicode/utf8"
)

type editorVersion [3]*big.Int

var editorOtherDigitRanges = [][2]rune{
	{0xb2, 0xb3}, {0xb9, 0xb9}, {0x1369, 0x1371}, {0x19da, 0x19da},
	{0x2070, 0x2070}, {0x2074, 0x2079}, {0x2080, 0x2089}, {0x2460, 0x2468},
	{0x2474, 0x247c}, {0x2488, 0x2490}, {0x24ea, 0x24ea}, {0x24f5, 0x24fd},
	{0x24ff, 0x24ff}, {0x2776, 0x277e}, {0x2780, 0x2788}, {0x278a, 0x2792},
	{0x10a40, 0x10a43}, {0x10e60, 0x10e68}, {0x11052, 0x1105a}, {0x1f100, 0x1f10a},
}

var editorDecimalRanges = [][2]rune{
	{'0', '9'}, {0x660, 0x669}, {0x6f0, 0x6f9}, {0x7c0, 0x7c9},
	{0x966, 0x96f}, {0x9e6, 0x9ef}, {0xa66, 0xa6f}, {0xae6, 0xaef},
	{0xb66, 0xb6f}, {0xbe6, 0xbef}, {0xc66, 0xc6f}, {0xce6, 0xcef},
	{0xd66, 0xd6f}, {0xde6, 0xdef}, {0xe50, 0xe59}, {0xed0, 0xed9},
	{0xf20, 0xf29}, {0x1040, 0x1049}, {0x1090, 0x1099}, {0x17e0, 0x17e9},
	{0x1810, 0x1819}, {0x1946, 0x194f}, {0x19d0, 0x19d9}, {0x1a80, 0x1a89},
	{0x1a90, 0x1a99}, {0x1b50, 0x1b59}, {0x1bb0, 0x1bb9}, {0x1c40, 0x1c49},
	{0x1c50, 0x1c59}, {0xa620, 0xa629}, {0xa8d0, 0xa8d9}, {0xa900, 0xa909},
	{0xa9d0, 0xa9d9}, {0xa9f0, 0xa9f9}, {0xaa50, 0xaa59}, {0xabf0, 0xabf9},
	{0xff10, 0xff19}, {0x104a0, 0x104a9}, {0x10d30, 0x10d39}, {0x11066, 0x1106f},
	{0x110f0, 0x110f9}, {0x11136, 0x1113f}, {0x111d0, 0x111d9}, {0x112f0, 0x112f9},
	{0x11450, 0x11459}, {0x114d0, 0x114d9}, {0x11650, 0x11659}, {0x116c0, 0x116c9},
	{0x11730, 0x11739}, {0x118e0, 0x118e9}, {0x11950, 0x11959}, {0x11c50, 0x11c59},
	{0x11d50, 0x11d59}, {0x11da0, 0x11da9}, {0x16a60, 0x16a69}, {0x16ac0, 0x16ac9},
	{0x16b50, 0x16b59}, {0x1d7ce, 0x1d7ff}, {0x1e140, 0x1e149}, {0x1e2f0, 0x1e2f9},
	{0x1e950, 0x1e959}, {0x1fbf0, 0x1fbf9},
}

func EditorVersionMetadata(stamp *ConfigValue, stampMissing bool, current *ConfigValue) (*ConfigValue, error) {
	return editorVersionMetadata(stamp, stampMissing, current, 4300)
}

func editorVersionMetadata(stamp *ConfigValue, stampMissing bool, current *ConfigValue, maxDigits int) (*ConfigValue, error) {
	if current == nil || current.Kind != "str" {
		return nil, configTypeError{"current must be a string"}
	}
	parsedCurrent, err := editorParseSemver(current.Text, maxDigits)
	if err != nil {
		return nil, err
	}
	var parsedStamp *editorVersion
	if stamp != nil && stamp.Kind == "str" && editorStrictStamp(stamp.Text) {
		parsedStamp, err = editorParseSemver(stamp.Text, maxDigits)
		if err != nil {
			return nil, err
		}
	}
	newer := parsedCurrent != nil && parsedStamp != nil && editorVersionCompare(*parsedStamp, *parsedCurrent) > 0
	return editorDict(
		editorField("pop_version", &ConfigValue{Kind: "bool", Bool: stampMissing}),
		editorField("newer", &ConfigValue{Kind: "bool", Bool: newer}),
	), nil
}

func editorVersionFromArguments(arguments *ConfigValue) (*ConfigValue, error) {
	stamp, err := editorRequiredField(arguments, "stamp")
	if err != nil {
		return nil, err
	}
	missing, err := editorRequiredField(arguments, "stamp_missing")
	if err != nil {
		return nil, err
	}
	current, err := editorRequiredField(arguments, "current")
	if err != nil {
		return nil, err
	}
	if missing.Kind != "bool" {
		return nil, configTypeError{"stamp_missing must be a bool"}
	}
	maxDigits := 4300
	if maximum, ok := arguments.Field("max_digits"); ok {
		if maximum.Kind != "int" {
			return nil, configTypeError{"max_digits must be an int"}
		}
		maxDigits, err = strconv.Atoi(maximum.Text)
		if err != nil || maxDigits < 0 {
			return nil, configTypeError{"max_digits must be a non-negative int"}
		}
	}
	return editorVersionMetadata(stamp, missing.Bool, current, maxDigits)
}

func editorParseSemver(value string, maxDigits int) (*editorVersion, error) {
	if value == "" {
		return nil, nil
	}
	core := strings.TrimFunc(value, editorPythonSpace)
	core = strings.TrimLeft(core, "vV")
	if index := strings.IndexByte(core, '-'); index >= 0 {
		core = core[:index]
	}
	if index := strings.IndexByte(core, '+'); index >= 0 {
		core = core[:index]
	}
	parts := strings.Split(core, ".")
	if len(parts) < 3 {
		return nil, nil
	}
	for _, part := range parts[:3] {
		if part == "" || !editorPythonDigits(part) {
			return nil, nil
		}
	}
	parsed := editorVersion{}
	for index, part := range parts[:3] {
		ascii, ok := editorDecimalASCII(part)
		if !ok {
			return nil, ValidationError{fmt.Sprintf("invalid literal for int() with base 10: '%s'", part)}
		}
		digits := utf8.RuneCountInString(part)
		if maxDigits > 0 && digits > maxDigits {
			return nil, ValidationError{fmt.Sprintf("Exceeds the limit (%d digits) for integer string conversion: value has %d digits; use sys.set_int_max_str_digits() to increase the limit", maxDigits, digits)}
		}
		parsed[index] = new(big.Int)
		parsed[index].SetString(ascii, 10)
	}
	return &parsed, nil
}

func editorPythonDigits(value string) bool {
	for _, char := range value {
		if editorDecimalDigit(char) || editorOtherDigit(char) {
			continue
		}
		return false
	}
	return value != ""
}

func editorOtherDigit(char rune) bool {
	for _, limits := range editorOtherDigitRanges {
		if char >= limits[0] && char <= limits[1] {
			return true
		}
	}
	return false
}

func editorDecimalDigit(char rune) bool {
	for _, limits := range editorDecimalRanges {
		if char >= limits[0] && char <= limits[1] {
			return true
		}
	}
	return false
}

func editorDecimalASCII(value string) (string, bool) {
	var out strings.Builder
	for len(value) != 0 {
		char, size := utf8.DecodeRuneInString(value)
		if char == utf8.RuneError && size == 1 || !editorDecimalDigit(char) {
			return "", false
		}
		start := rune(0)
		for _, limits := range editorDecimalRanges {
			if char >= limits[0] && char <= limits[1] {
				start = limits[0]
				break
			}
		}
		out.WriteByte(byte('0' + (char-start)%10))
		value = value[size:]
	}
	return out.String(), true
}

func editorPythonSpace(char rune) bool {
	return unicode.IsSpace(char) || char >= 0x1c && char <= 0x1f
}

func editorStrictStamp(value string) bool {
	parts := strings.Split(value, ".")
	if len(parts) != 3 {
		return false
	}
	for _, part := range parts {
		if len(part) < 1 || len(part) > 4 {
			return false
		}
		for _, char := range part {
			if char < '0' || char > '9' {
				return false
			}
		}
	}
	return true
}

func editorVersionCompare(left, right editorVersion) int {
	for index := range left {
		if comparison := left[index].Cmp(right[index]); comparison != 0 {
			return comparison
		}
	}
	return 0
}
