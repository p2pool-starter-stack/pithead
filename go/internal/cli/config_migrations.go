package cli

import (
	"bytes"
	"io"
	"strconv"

	"github.com/p2pool-starter-stack/pithead/go/internal/config"
)

func configMigrations(args []string, input io.Reader, output io.Writer) error {
	unsupported := &ExitError{Code: 125}
	if len(args) != 1 {
		return unsupported
	}
	raw, err := io.ReadAll(input)
	if err != nil {
		return unsupported
	}
	fields := bytes.Split(raw, []byte{0})
	var rendered []byte
	switch args[0] {
	case "workers-plan", "workers-json":
		if len(fields) != 5 || len(fields[4]) != 0 || !bytes.Equal(fields[3], []byte("0")) {
			return unsupported
		}
		if args[0] == "workers-plan" {
			plan, planErr := config.PlanLegacyWorkers(fields[0], fields[1], fields[2])
			if planErr != nil {
				return unsupported
			}
			rendered = appendMigrationFields(plan.Conflict, strconv.FormatBool(plan.Need), strconv.FormatBool(plan.Populated))
		} else {
			rendered, err = config.MigrateLegacyWorkers(fields[0], fields[1], fields[2])
		}
	case "telegram-plan", "telegram-json":
		if len(fields) != 3 || len(fields[2]) != 0 || !bytes.Equal(fields[1], []byte("0")) {
			return unsupported
		}
		if args[0] == "telegram-plan" {
			plan, planErr := config.PlanTelegramControl(fields[0])
			if planErr != nil {
				return unsupported
			}
			rendered = appendMigrationFields(strconv.FormatBool(plan.Need), strconv.FormatBool(plan.WarnEnabled))
		} else {
			rendered, err = config.MigrateTelegramControl(fields[0])
		}
	default:
		return unsupported
	}
	if err != nil {
		return unsupported
	}
	if bytes.HasSuffix([]byte(args[0]), []byte("json")) {
		rendered = append(rendered, 0)
	}
	if _, err := output.Write(rendered); err != nil {
		return unsupported
	}
	return nil
}

func appendMigrationFields(fields ...string) []byte {
	var rendered []byte
	for _, field := range fields {
		rendered = append(rendered, field...)
		rendered = append(rendered, 0)
	}
	return rendered
}
