package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configVersion(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) == 0 {
		return unsupported
	}
	switch args[0] {
	case "normalize":
		if len(args) != 2 {
			return unsupported
		}
		normalized, valid, err := config.NormalizeCodeVersion(args[1])
		if err != nil {
			return unsupported
		}
		if !valid {
			return &ExitError{Code: 1}
		}
		if _, err := io.WriteString(output, normalized+"\x00"); err != nil {
			return unsupported
		}
		return nil
	case "ok":
		if len(args) != 2 {
			return unsupported
		}
		valid, err := config.ConfigVersionOK(args[1])
		if err != nil {
			return unsupported
		}
		if !valid {
			return &ExitError{Code: 1}
		}
		return nil
	case "plan", "json":
		if len(args) != 1 {
			return unsupported
		}
		return configVersionDocument(args[0], input, output)
	default:
		return unsupported
	}
}

func configVersionDocument(operation string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	if len(fields) != 4 || len(fields[3]) != 0 || !bytes.Equal(fields[2], []byte("0")) {
		return unsupported
	}
	var rendered []byte
	if operation == "plan" {
		plan, planErr := config.PlanConfigVersion(fields[0], string(fields[1]))
		if planErr != nil {
			return unsupported
		}
		for _, value := range []string{plan.Stamp, strconv.FormatBool(plan.Newer), strconv.FormatBool(plan.Malformed), strconv.FormatBool(plan.EqualPresent)} {
			rendered = append(rendered, value...)
			rendered = append(rendered, 0)
		}
	} else {
		rendered, err = config.StampConfigVersion(fields[0], string(fields[1]))
		if err != nil {
			return unsupported
		}
		rendered = append(rendered, 0)
	}
	if _, err := output.Write(rendered); err != nil {
		return unsupported
	}
	return nil
}
