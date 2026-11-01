package config

type DashboardAccessInput struct {
	Platform string
}

type DashboardAccess struct {
	Assigned          int
	Values            [5]string
	Reason            string
	NeedsHostTimezone bool
}

func ParseDashboardAccess(raw, table []byte, input DashboardAccessInput) (DashboardAccess, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return DashboardAccess{}, ErrUnsupportedValidation
	}
	defaults, err := NewDefaults(table)
	if err != nil {
		return DashboardAccess{}, ErrUnsupportedValidation
	}
	fallbacks, err := defaults.renderNode("legacy", input.Platform)
	if err != nil {
		return DashboardAccess{}, ErrUnsupportedValidation
	}
	hostFallback, err := getStringPath(fallbacks, "dashboard.host")
	if err != nil || isNull(hostFallback) {
		return DashboardAccess{}, ErrUnsupportedValidation
	}

	settings := DashboardAccess{}
	settings.Values[0], err = networkSettingsScalar(document.root, "dashboard.host", hostFallback, true)
	if err != nil {
		return DashboardAccess{}, err
	}
	settings.Values[0] = dashboardAccessResolveDefault(settings.Values[0])
	settings.Assigned = 1
	if settings.Values[0] != "" && !networkSettingsHost(settings.Values[0]) {
		settings.Reason = `dashboard.host must be a hostname or IP address — only letters, digits, dots, hyphens, and colons (got "` + settings.Values[0] + `").`
		return settings, nil
	}

	settings.Values[1], err = networkSettingsScalar(document.root, "dashboard.port", node{value: ""}, false)
	if err != nil {
		return DashboardAccess{}, err
	}
	settings.Values[1] = dashboardAccessResolveDefault(settings.Values[1])
	settings.Assigned = 2
	if settings.Values[1] != "" && !networkSettingsPort(settings.Values[1]) {
		settings.Reason = `dashboard.port must be a whole number between 1 and 65535, or "auto" (got "` + settings.Values[1] + `").`
		return settings, nil
	}

	settings.Values[2], err = networkSettingsScalar(document.root, "dashboard.secure", node{value: true}, true)
	if err != nil {
		return DashboardAccess{}, err
	}
	settings.Assigned = 3
	settings.Values[3], err = networkSettingsScalar(document.root, "dashboard.expose_public_ip", node{value: false}, true)
	if err != nil {
		return DashboardAccess{}, err
	}
	settings.Assigned = 4
	settings.Values[4], err = networkSettingsScalar(document.root, "dashboard.timezone", node{value: ""}, false)
	if err != nil {
		return DashboardAccess{}, err
	}
	settings.Values[4] = dashboardAccessResolveDefault(settings.Values[4])
	settings.NeedsHostTimezone = settings.Values[4] == ""
	settings.Assigned = 5
	return settings, nil
}

func dashboardAccessResolveDefault(value string) string {
	switch value {
	case "", "auto", "DYNAMIC_DATA", "DYNAMIC_HOST", "DYNAMIC_ID":
		return ""
	default:
		return value
	}
}
