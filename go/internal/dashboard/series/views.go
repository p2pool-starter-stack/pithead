package series

func GaugePoints(rows []map[string]any, rangeArg string, window *[2]float64, cols []string, now float64) (any, error) {
	return gaugePoints(rows, rangeArg, window, cols, now)
}

func FilterRows(rows []map[string]any, rangeArg string, window *[2]float64, now float64) ([]map[string]any, error) {
	return filterRows(rows, rangeArg, window, now)
}

func EpochMillis(timestamp any) (any, error) {
	return epochMillis(map[string]any{"ts": timestamp})
}
