package infra

import (
	"encoding/json"
	"errors"
	"fmt"
	"strconv"
	"strings"
)

func buildSystem(raw []json.RawMessage) (any, error) {
	args, err := arguments(raw, 1)
	if err != nil {
		return nil, err
	}
	data, err := object(args[0])
	if err != nil {
		return nil, err
	}
	system, err := objectMember(data, "system")
	if err != nil {
		return nil, err
	}
	disk, err := objectMember(system, "disk")
	if err != nil {
		return nil, err
	}
	used, total, unit := diskSize(member(disk, "used_gb", json.Number("0")), member(disk, "total_gb", json.Number("0")))
	diskPercent := member(disk, "percent", json.Number("0"))
	if _, ok := diskPercent.(string); ok {
		return nil, errors.New("invalid disk percentage")
	}
	diskNumber, err := number(diskPercent)
	if err != nil {
		return nil, err
	}
	fill := ""
	if diskNumber > 90 {
		fill = "critical"
	} else if diskNumber > 70 {
		fill = "warning"
	}
	memory, err := objectMember(system, "memory")
	if err != nil {
		return nil, err
	}
	cpu, ok := member(system, "cpu_percent", "0.0%").(string)
	if !ok {
		return nil, errors.New("invalid CPU percentage")
	}
	cpuNumber, err := strconv.ParseFloat(strings.Trim(cpu, "%"), 64)
	if err != nil {
		cpuNumber = 0
	}
	load, ok := member(system, "load", "0.00 0.00 0.00").(string)
	if !ok {
		return nil, errors.New("invalid load average")
	}
	parts := strings.Fields(load)
	if len(parts) == 3 {
		load = fmt.Sprintf("1m: %s 5m: %s 15m: %s", parts[0], parts[1], parts[2])
	}
	hugepages := member(system, "hugepages", []any{"Disabled", "status-bad", "0/0"})
	hp, ok := hugepages.([]any)
	if !ok || len(hp) != 3 {
		return nil, errors.New("invalid HugePages state")
	}
	memUsed, err := decimal(member(memory, "used_gb", json.Number("0")), 1)
	if err != nil {
		return nil, err
	}
	memTotal, err := decimal(member(memory, "total_gb", json.Number("0")), 1)
	if err != nil {
		return nil, err
	}
	memPercent := member(memory, "percent", json.Number("0"))
	if _, ok := memPercent.(string); ok {
		return nil, errors.New("invalid memory percentage")
	}
	memNumber, err := number(memPercent)
	if err != nil {
		return nil, err
	}
	variant := "bad"
	if hp[1] == "status-ok" {
		variant = "ok"
	}
	return map[string]any{
		"cpu":       map[string]any{"percent": cpu, "load": load, "level": usageLevel(cpuNumber, 80)},
		"mem":       map[string]any{"used": memUsed, "total": memTotal, "percent": member(memory, "percent_str", "0%"), "level": usageLevel(memNumber, 80)},
		"disk":      map[string]any{"used": used, "total": total, "unit": unit, "percent": member(disk, "percent_str", "0%"), "width": pythonString(diskPercent) + "%", "fill": fill, "level": usageLevel(diskNumber, 80)},
		"hugepages": map[string]any{"status": hp[0], "value": hp[2], "variant": variant},
	}, nil
}

func diskSize(usedValue, totalValue any) (string, string, string) {
	if !truthy(usedValue) {
		usedValue = json.Number("0")
	}
	if !truthy(totalValue) {
		totalValue = json.Number("0")
	}
	used, usedErr := number(usedValue)
	total, totalErr := number(totalValue)
	if usedErr != nil || totalErr != nil {
		used, total = 0, 0
	}
	if total >= 1024 {
		return fmt.Sprintf("%.1f", used/1024), fmt.Sprintf("%.1f", total/1024), "TB"
	}
	return fmt.Sprintf("%.1f", used), fmt.Sprintf("%.1f", total), "GB"
}

func usageLevel(percent, threshold float64) string {
	if percent > threshold {
		return "high"
	}
	return "ok"
}
