package lifecycle

import "strings"

func PlanKeepRunning(keepRaw string, originalArgs, capturedServices []string) []string {
	opts := make([]string, 0, len(originalArgs))
	for _, arg := range originalArgs {
		if arg == "--remove-orphans" {
			continue
		}
		if strings.HasPrefix(arg, "-") {
			opts = append(opts, arg)
		}
	}
	services := make([]string, 0, len(capturedServices))
	keep := " " + keepRaw + " "
	for _, service := range capturedServices {
		if !strings.Contains(keep, " "+service+" ") {
			services = append(services, service)
		}
	}
	if len(services) == 0 {
		return []string{}
	}
	result := make([]string, 0, len(opts)+1+len(services))
	result = append(result, opts...)
	result = append(result, "--no-deps")
	result = append(result, services...)
	return result
}
