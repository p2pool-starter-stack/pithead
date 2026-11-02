package wizard

import (
	"math"
	"math/big"
)

func configEqual(left, right *ConfigValue, member bool) bool {
	if left == nil || right == nil {
		return left == right
	}
	if numericKind(left.Kind) && numericKind(right.Kind) {
		return numericEqual(left, right, member)
	}
	if left.Kind != right.Kind {
		return false
	}
	switch left.Kind {
	case "null":
		return true
	case "bool":
		return left.Bool == right.Bool
	case "str":
		return left.Text == right.Text
	case "list":
		if len(left.Items) != len(right.Items) {
			return false
		}
		for index := range left.Items {
			if !configEqual(left.Items[index], right.Items[index], true) {
				return false
			}
		}
		return true
	case "dict":
		if len(left.Fields) != len(right.Fields) {
			return false
		}
		for _, field := range left.Fields {
			other, ok := right.Field(field.Key)
			if !ok || !configEqual(field.Value, other, true) {
				return false
			}
		}
		return true
	default:
		return false
	}
}

func numericKind(kind string) bool {
	return kind == "bool" || kind == "int" || kind == "float"
}

func numericEqual(left, right *ConfigValue, member bool) bool {
	if left.Kind != "float" && right.Kind != "float" {
		leftInt, leftOK := configInteger(left)
		rightInt, rightOK := configInteger(right)
		return leftOK && rightOK && leftInt.Cmp(rightInt) == 0
	}
	if left.Kind == "float" && right.Kind == "float" {
		leftFloat, leftErr := parseFloat(left.Text)
		rightFloat, rightErr := parseFloat(right.Text)
		if leftErr != nil || rightErr != nil {
			return false
		}
		if math.IsNaN(leftFloat) || math.IsNaN(rightFloat) {
			return member && math.IsNaN(leftFloat) && math.IsNaN(rightFloat) && left.Identity != 0 && left.Identity == right.Identity
		}
		return leftFloat == rightFloat
	}
	if left.Kind == "float" {
		left, right = right, left
	}
	integer, ok := configInteger(left)
	floating, err := parseFloat(right.Text)
	if !ok || err != nil || math.IsNaN(floating) || math.IsInf(floating, 0) {
		return false
	}
	floatRat := new(big.Rat).SetFloat64(floating)
	return floatRat != nil && floatRat.Cmp(new(big.Rat).SetInt(integer)) == 0
}

func configInteger(value *ConfigValue) (*big.Int, bool) {
	if value.Kind == "bool" {
		if value.Bool {
			return big.NewInt(1), true
		}
		return big.NewInt(0), true
	}
	integer, ok := new(big.Int).SetString(value.Text, 10)
	return integer, ok
}

func strictConfigEqual(left, right *ConfigValue) bool {
	return left != nil && right != nil && left.Kind == right.Kind && left.Equal(right)
}
