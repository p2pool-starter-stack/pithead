package config

import "encoding/json"

func nodeEqual(left, right node) bool {
	if left.object != nil || right.object != nil {
		if left.object == nil || right.object == nil || len(left.object) != len(right.object) {
			return false
		}
		for _, item := range left.object {
			candidate, ok := objectValue(right, item.key)
			if !ok || !nodeEqual(item.value, candidate) {
				return false
			}
		}
		return true
	}
	if left.array != nil || right.array != nil {
		if left.array == nil || right.array == nil || len(left.array) != len(right.array) {
			return false
		}
		for index := range left.array {
			if !nodeEqual(left.array[index], right.array[index]) {
				return false
			}
		}
		return true
	}
	leftNumber, leftIsNumber := left.value.(json.Number)
	rightNumber, rightIsNumber := right.value.(json.Number)
	if leftIsNumber || rightIsNumber {
		return leftIsNumber && rightIsNumber && leftNumber.String() == rightNumber.String()
	}
	return left.value == right.value
}

func objectMember(root node, key string) node {
	value, _ := objectValue(root, key)
	return cloneNode(value)
}

func setObjectMember(root *node, key string, value node) {
	for index := range root.object {
		if root.object[index].key == key {
			root.object[index].value = cloneNode(value)
			return
		}
	}
	root.object = append(root.object, member{key: key, value: cloneNode(value)})
}

func deleteObjectMember(root *node, key string) {
	for index := range root.object {
		if root.object[index].key == key {
			root.object = append(root.object[:index], root.object[index+1:]...)
			return
		}
	}
}

func migrationJSON(root node) ([]byte, error) {
	rendered, err := prettyJQ(root)
	if err != nil {
		return nil, ErrUnsupportedMigration
	}
	return rendered, nil
}
