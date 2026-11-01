package lifecycle

import "errors"

var ErrUnsupported = errors.New("unsupported lifecycle verb")

type Options struct {
	Yes       bool
	DryRun    bool
	Porcelain bool
}

type Verdict struct {
	Kind     string
	Argument string
	Options  Options
}

func ParseOptions(verb string, args []string) (Verdict, error) {
	result := Verdict{Kind: "ok"}
	switch verb {
	case "render", "up", "down":
		if len(args) != 0 {
			result.Kind = "unknown"
			result.Argument = args[0]
		}
	case "apply":
		for _, arg := range args {
			switch arg {
			case "-y", "--yes":
				result.Options.Yes = true
			case "--dry-run":
				result.Options.DryRun = true
			case "--porcelain":
				result.Options.Porcelain = true
			default:
				result.Kind = "unknown"
				result.Argument = arg
				return result, nil
			}
		}
		if result.Options.Porcelain && !result.Options.DryRun {
			result.Kind = "porcelain-needs-dry-run"
		}
	case "restart":
		if len(args) == 0 || args[0] == "" || args[0] == "tor" || args[0] == "monerod" {
			return result, nil
		}
		result.Kind = "unknown"
		result.Argument = args[0]
	default:
		return Verdict{}, ErrUnsupported
	}
	return result, nil
}
