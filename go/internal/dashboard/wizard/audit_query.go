package wizard

import (
	"math"
	"math/big"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

func auditQuery(arguments *ConfigValue) (*ConfigValue, error) {
	from, err := auditField(arguments, "from")
	if err != nil {
		return nil, err
	}
	to, err := auditField(arguments, "to")
	if err != nil {
		return nil, err
	}
	query, err := auditField(arguments, "query")
	if err != nil {
		return nil, err
	}
	if !auditQueryBound(from) || !auditQueryBound(to) {
		return nil, configTypeError{"query bounds must be floats or None"}
	}
	if query.Kind != "str" {
		return nil, configTypeError{"query must be a string"}
	}
	from = auditFiniteBound(from)
	to = auditFiniteBound(to)
	queryText := auditCodepointPrefix(query.Text, 200)
	queryValue := &ConfigValue{Kind: "null"}
	if queryText != "" {
		queryValue = configString(queryText)
	}
	return &ConfigValue{Kind: "list", Items: []*ConfigValue{from, to, queryValue}}, nil
}

func auditWindow(arguments *ConfigValue) (*ConfigValue, error) {
	epochs, err := auditField(arguments, "epochs")
	if err != nil {
		return nil, err
	}
	from, err := auditField(arguments, "from")
	if err != nil {
		return nil, err
	}
	to, err := auditField(arguments, "to")
	if err != nil {
		return nil, err
	}
	if epochs.Kind != "list" {
		return nil, configTypeError{"epochs must be a list"}
	}
	if !auditBound(from) || !auditBound(to) {
		return nil, configTypeError{"audit bounds must be numbers or None"}
	}
	indices := make([]int, 0, len(epochs.Items))
	for index, epoch := range epochs.Items {
		if epoch == nil || epoch.Kind == "null" {
			if from.Kind == "null" && to.Kind == "null" {
				indices = append(indices, index)
			}
			continue
		}
		if !numericKind(epoch.Kind) {
			return nil, configTypeError{"epochs must contain numbers or None"}
		}
		if from.Kind != "null" {
			comparison, comparable := auditNumberCompare(epoch, from)
			if comparable && comparison < 0 {
				continue
			}
		}
		if to.Kind != "null" {
			comparison, comparable := auditNumberCompare(epoch, to)
			if comparable && comparison >= 0 {
				continue
			}
		}
		indices = append(indices, index)
	}
	return auditIndices(indices), nil
}

func auditFilter(arguments *ConfigValue) (*ConfigValue, error) {
	epochs, err := auditField(arguments, "epochs")
	if err != nil {
		return nil, err
	}
	fields, err := auditField(arguments, "fields")
	if err != nil {
		return nil, err
	}
	if epochs.Kind != "list" || fields.Kind != "list" {
		return nil, configTypeError{"epochs and fields must be lists"}
	}
	if len(epochs.Items) != len(fields.Items) {
		return nil, configTypeError{"epochs and fields must have equal lengths"}
	}
	window, err := auditWindow(arguments)
	if err != nil {
		return nil, err
	}
	search, err := auditSearch(arguments)
	if err != nil {
		return nil, err
	}
	matched := make([]bool, len(fields.Items))
	for _, index := range search.Items {
		value, _ := strconv.Atoi(index.Text)
		matched[value] = true
	}
	indices := make([]int, 0, len(window.Items))
	for _, index := range window.Items {
		value, _ := strconv.Atoi(index.Text)
		if matched[value] {
			indices = append(indices, value)
		}
	}
	return auditIndices(indices), nil
}

func auditSearch(arguments *ConfigValue) (*ConfigValue, error) {
	fields, err := auditField(arguments, "fields")
	if err != nil {
		return nil, err
	}
	query, err := auditField(arguments, "query")
	if err != nil {
		return nil, err
	}
	if fields.Kind != "list" {
		return nil, configTypeError{"fields must be a list"}
	}
	if query.Kind != "str" {
		return nil, configTypeError{"query must be a string"}
	}
	indices := make([]int, 0, len(fields.Items))
	for index, row := range fields.Items {
		if row == nil || row.Kind != "list" {
			return nil, configTypeError{"fields must contain lists"}
		}
		matched := query.Text == ""
		for _, field := range row.Items {
			if field == nil || field.Kind != "str" {
				return nil, configTypeError{"search fields must be strings"}
			}
			if strings.Contains(field.Text, query.Text) {
				matched = true
			}
		}
		if matched {
			indices = append(indices, index)
		}
	}
	return auditIndices(indices), nil
}

func auditMerge(arguments *ConfigValue) (*ConfigValue, error) {
	rowsValue, err := auditField(arguments, "rows")
	if err != nil {
		return nil, err
	}
	if rowsValue.Kind != "list" {
		return nil, configTypeError{"rows must be a list"}
	}
	rows := make([]auditMergeRow, len(rowsValue.Items))
	for index, value := range rowsValue.Items {
		row, rowErr := auditMergeValue(value, index)
		if rowErr != nil {
			return nil, rowErr
		}
		rows[index] = row
	}
	selected := make(map[string]int, len(rows))
	keys := make([]string, 0, len(rows))
	for _, control := range []bool{false, true} {
		for _, row := range rows {
			if row.control != control || !control && row.id == "" {
				continue
			}
			key := row.id
			if control && key == "" {
				key = "log-" + row.synthetic
			}
			_, exists := selected[key]
			if control && row.id != "" && exists {
				continue
			}
			if !exists {
				keys = append(keys, key)
			}
			selected[key] = row.index
		}
	}
	indices := make([]int, len(keys))
	for index, key := range keys {
		indices[index] = selected[key]
	}
	sort.SliceStable(indices, func(left, right int) bool {
		return rows[indices[left]].ts > rows[indices[right]].ts
	})
	return auditIndices(indices), nil
}

type auditMergeRow struct {
	index     int
	id        string
	ts        string
	control   bool
	synthetic string
}

func auditMergeValue(value *ConfigValue, index int) (auditMergeRow, error) {
	if value == nil || value.Kind != "dict" {
		return auditMergeRow{}, configTypeError{"rows must contain objects"}
	}
	id, idOK := value.Field("id")
	ts, tsOK := value.Field("ts")
	control, controlOK := value.Field("control")
	synthetic, syntheticOK := value.Field("synthetic")
	if !idOK || !tsOK || !controlOK || !syntheticOK {
		return auditMergeRow{}, configTypeError{"audit merge rows require id, ts, control, and synthetic"}
	}
	if id.Kind != "str" || ts.Kind != "str" || control.Kind != "bool" || synthetic.Kind != "str" {
		return auditMergeRow{}, configTypeError{"invalid audit merge row fields"}
	}
	return auditMergeRow{index: index, id: id.Text, ts: ts.Text, control: control.Bool, synthetic: synthetic.Text}, nil
}

func auditBound(value *ConfigValue) bool {
	return value != nil && (value.Kind == "null" || numericKind(value.Kind))
}

func auditQueryBound(value *ConfigValue) bool {
	return value != nil && (value.Kind == "null" || value.Kind == "float")
}

func auditFiniteBound(value *ConfigValue) *ConfigValue {
	if value.Kind == "null" {
		return value.Clone()
	}
	floating, _ := parseFloat(value.Text)
	if math.IsNaN(floating) || math.IsInf(floating, 0) {
		return &ConfigValue{Kind: "null"}
	}
	return value.Clone()
}

func auditCodepointPrefix(value string, limit int) string {
	end := 0
	for count := 0; end < len(value) && count < limit; count++ {
		_, size := utf8.DecodeRuneInString(value[end:])
		if size == 1 && end+3 <= len(value) && value[end] == 0xed && value[end+1] >= 0xa0 && value[end+1] <= 0xbf && value[end+2] >= 0x80 && value[end+2] <= 0xbf {
			size = 3
		}
		end += size
	}
	return value[:end]
}

func auditNumberCompare(left, right *ConfigValue) (int, bool) {
	if left.Kind != "float" && right.Kind != "float" {
		leftInt, leftOK := configInteger(left)
		rightInt, rightOK := configInteger(right)
		if !leftOK || !rightOK {
			return 0, false
		}
		return leftInt.Cmp(rightInt), true
	}
	leftFloat, leftIsFloat, leftOK := auditFloat(left)
	rightFloat, rightIsFloat, rightOK := auditFloat(right)
	if !leftOK || !rightOK || leftIsFloat && math.IsNaN(leftFloat) || rightIsFloat && math.IsNaN(rightFloat) {
		return 0, false
	}
	if leftIsFloat && math.IsInf(leftFloat, 0) {
		if rightIsFloat && leftFloat == rightFloat {
			return 0, true
		}
		if math.IsInf(leftFloat, 1) {
			return 1, true
		}
		return -1, true
	}
	if rightIsFloat && math.IsInf(rightFloat, 0) {
		return -auditInfSign(rightFloat), true
	}
	return auditNumberRat(left, leftFloat, leftIsFloat).Cmp(auditNumberRat(right, rightFloat, rightIsFloat)), true
}

func auditFloat(value *ConfigValue) (float64, bool, bool) {
	if value.Kind != "float" {
		return 0, false, numericKind(value.Kind)
	}
	floating, err := parseFloat(value.Text)
	return floating, true, err == nil
}

func auditNumberRat(value *ConfigValue, floating float64, isFloat bool) *big.Rat {
	if isFloat {
		return new(big.Rat).SetFloat64(floating)
	}
	integer, _ := configInteger(value)
	return new(big.Rat).SetInt(integer)
}

func auditInfSign(value float64) int {
	if math.IsInf(value, 1) {
		return 1
	}
	return -1
}

func auditIndices(indices []int) *ConfigValue {
	items := make([]*ConfigValue, len(indices))
	for index, value := range indices {
		items[index] = &ConfigValue{Kind: "int", Text: strconv.Itoa(value)}
	}
	return &ConfigValue{Kind: "list", Items: items}
}
