package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/lifecycle"
)

const (
	keepRunningMaxInput = 1 << 20
	keepRunningMaxItems = 8192
)

func keepRunningScope(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 0 {
		return unsupported
	}
	raw, err := io.ReadAll(io.LimitReader(input, keepRunningMaxInput+1))
	if err != nil || len(raw) > keepRunningMaxInput {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) < 5 || len(fields[len(fields)-1]) != 0 {
		return unsupported
	}
	argCount, ok := keepRunningCount(fields[1])
	if !ok || argCount > keepRunningMaxItems || len(fields) < argCount+5 {
		return unsupported
	}
	serviceCountIndex := argCount + 2
	serviceCount, ok := keepRunningCount(fields[serviceCountIndex])
	if !ok || serviceCount > keepRunningMaxItems-argCount || len(fields) != argCount+serviceCount+5 {
		return unsupported
	}
	statusIndex := argCount + serviceCount + 3
	if !bytes.Equal(fields[statusIndex], []byte("0")) {
		return unsupported
	}
	originalArgs := make([]string, argCount)
	for index := range originalArgs {
		originalArgs[index] = string(fields[index+2])
	}
	services := make([]string, serviceCount)
	for index := range services {
		services[index] = string(fields[serviceCountIndex+1+index])
	}
	result := lifecycle.PlanKeepRunning(string(fields[0]), originalArgs, services)
	encoded := []byte(strconv.Itoa(len(result)))
	encoded = append(encoded, 0)
	for _, value := range result {
		encoded = append(encoded, value...)
		encoded = append(encoded, 0)
	}
	written, err := output.Write(encoded)
	if err != nil || written != len(encoded) {
		return unsupported
	}
	return nil
}

func keepRunningCount(field []byte) (int, bool) {
	value, err := strconv.Atoi(string(field))
	return value, err == nil && value >= 0 && strconv.Itoa(value) == string(field)
}
