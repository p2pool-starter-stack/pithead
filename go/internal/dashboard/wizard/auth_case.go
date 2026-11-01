package wizard

import (
	"strings"
	"unicode"
)

var pythonUpperExpansions = map[rune]string{
	0x00df: "SS", 0x0149: "\u02bcN", 0x01f0: "J\u030c", 0x0390: "\u0399\u0308\u0301",
	0x03b0: "\u03a5\u0308\u0301", 0x0587: "\u0535\u0552", 0x1e96: "H\u0331",
	0x1e97: "T\u0308", 0x1e98: "W\u030a", 0x1e99: "Y\u030a", 0x1e9a: "A\u02be",
	0x1f50: "\u03a5\u0313", 0x1f52: "\u03a5\u0313\u0300", 0x1f54: "\u03a5\u0313\u0301",
	0x1f56: "\u03a5\u0313\u0342", 0x1fb2: "\u1fba\u0399", 0x1fb3: "\u0391\u0399",
	0x1fb4: "\u0386\u0399", 0x1fb6: "\u0391\u0342", 0x1fb7: "\u0391\u0342\u0399",
	0x1fbc: "\u0391\u0399", 0x1fc2: "\u1fca\u0399", 0x1fc3: "\u0397\u0399",
	0x1fc4: "\u0389\u0399", 0x1fc6: "\u0397\u0342", 0x1fc7: "\u0397\u0342\u0399",
	0x1fcc: "\u0397\u0399", 0x1fd2: "\u0399\u0308\u0300", 0x1fd3: "\u0399\u0308\u0301",
	0x1fd6: "\u0399\u0342", 0x1fd7: "\u0399\u0308\u0342", 0x1fe2: "\u03a5\u0308\u0300",
	0x1fe3: "\u03a5\u0308\u0301", 0x1fe4: "\u03a1\u0313", 0x1fe6: "\u03a5\u0342",
	0x1fe7: "\u03a5\u0308\u0342", 0x1ff2: "\u1ffa\u0399", 0x1ff3: "\u03a9\u0399",
	0x1ff4: "\u038f\u0399", 0x1ff6: "\u03a9\u0342", 0x1ff7: "\u03a9\u0342\u0399",
	0x1ffc: "\u03a9\u0399", 0xfb00: "FF", 0xfb01: "FI", 0xfb02: "FL",
	0xfb03: "FFI", 0xfb04: "FFL", 0xfb05: "ST", 0xfb06: "ST",
	0xfb13: "\u0544\u0546", 0xfb14: "\u0544\u0535", 0xfb15: "\u0544\u053b",
	0xfb16: "\u054e\u0546", 0xfb17: "\u0544\u053d",
}

func pythonUpper(value string) string {
	var result strings.Builder
	result.Grow(len(value))
	for _, r := range value {
		if expansion, ok := pythonUpperExpansions[r]; ok {
			result.WriteString(expansion)
			continue
		}
		if python14Identity(r) {
			result.WriteRune(r)
			continue
		}
		switch {
		case r >= 0x1f80 && r <= 0x1f8f:
			result.WriteRune(0x1f08 + (r & 7))
			result.WriteRune(0x0399)
		case r >= 0x1f90 && r <= 0x1f9f:
			result.WriteRune(0x1f28 + (r & 7))
			result.WriteRune(0x0399)
		case r >= 0x1fa0 && r <= 0x1faf:
			result.WriteRune(0x1f68 + (r & 7))
			result.WriteRune(0x0399)
		default:
			result.WriteRune(unicode.ToUpper(r))
		}
	}
	return result.String()
}

func python14Identity(r rune) bool {
	switch r {
	case 0x019b, 0x0264, 0x1c8a, 0xa7cd, 0xa7cf, 0xa7d3, 0xa7d5, 0xa7db:
		return true
	}
	return r >= 0x10d70 && r <= 0x10d85 || r >= 0x16ebb && r <= 0x16ed3
}
