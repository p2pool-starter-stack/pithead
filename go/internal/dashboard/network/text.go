package network

import (
	"fmt"
	"strings"
)

func contains(value, fragment string) bool {
	return strings.Contains(value, fragment)
}

func plural(count int, label string) string {
	return fmt.Sprintf("%d %s", count, label)
}
