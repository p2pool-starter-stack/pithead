package config

import "strings"

type DashboardAuth struct {
	Username string
	Password string
	Reason   string
}

type DashboardPolicyInput struct {
	Password string
	Program  string
}

type DashboardPolicy struct {
	Assigned int
	Values   [3]string
	Reason   string
}

func ParseDashboardAuth(raw []byte) (DashboardAuth, error) {
	document, err := dashboardAuthDocument(raw)
	if err != nil {
		return DashboardAuth{}, err
	}
	settings := DashboardAuth{}
	settings.Username, err = networkSettingsScalar(document.root, "dashboard.auth.username", node{value: "admin"}, false)
	if err != nil {
		return DashboardAuth{}, err
	}
	settings.Password, err = networkSettingsScalar(document.root, "dashboard.auth.password", node{value: ""}, false)
	if err != nil {
		return DashboardAuth{}, err
	}
	if settings.Password == "" {
		return settings, nil
	}
	if !dashboardPolicyASCII(settings.Username) {
		return DashboardAuth{}, ErrUnsupportedValidation
	}
	if !dashboardAuthUsername(settings.Username) {
		settings.Reason = `dashboard.auth.username must be 1–64 chars of letters, digits, and . _ @ - (got "` + settings.Username + `").`
		return settings, nil
	}
	valid, supported := dashboardAuthPassword(settings.Password)
	if !supported {
		return DashboardAuth{}, ErrUnsupportedValidation
	}
	if !valid {
		settings.Reason = `dashboard.auth.password must be 8–128 printable characters with no double-quotes.`
	}
	return settings, nil
}

func ParseDashboardPolicy(raw []byte, input DashboardPolicyInput) (DashboardPolicy, error) {
	document, err := dashboardAuthDocument(raw)
	if err != nil {
		return DashboardPolicy{}, err
	}
	policy := DashboardPolicy{}
	policy.Values[0], err = networkSettingsScalar(document.root, "dashboard.onion.enabled", node{value: false}, true)
	if err != nil {
		return DashboardPolicy{}, err
	}
	policy.Values[0] = normalizedBool(policy.Values[0])
	policy.Values[1] = "false"
	if policy.Values[0] == "true" {
		policy.Values[1], err = networkSettingsScalar(document.root, "dashboard.onion.client_auth", node{value: true}, true)
		if err != nil {
			return DashboardPolicy{}, err
		}
		policy.Values[1] = normalizedBool(policy.Values[1])
		policy.Assigned = 2
		if input.Password == "" {
			policy.Reason = "dashboard.onion.enabled is true but dashboard.auth.password is empty. Publishing the dashboard as a Tor onion exposes a control panel at a stable address — it must sit behind a login. Set a strong dashboard.auth.password (16+ characters) and re-run."
			return policy, nil
		}
		if !dashboardPolicyASCII(input.Password) {
			return DashboardPolicy{}, ErrUnsupportedValidation
		}
		if len(input.Password) < 16 {
			policy.Reason = "dashboard.auth.password must be at least 16 characters when dashboard.onion.enabled is true (a published .onion is online-brute-forceable and per-IP throttling is meaningless over Tor). Use a passphrase."
			return policy, nil
		}
		if dashboardPolicyRepeated(input.Password) {
			policy.Reason = "dashboard.auth.password is a single repeated character — choose a real passphrase."
			return policy, nil
		}
		lowered := strings.ToLower(input.Password)
		for _, pattern := range []string{"passwordpassword", "0123456789", "qwertyuiop", "changeme", "letmein"} {
			if strings.Contains(lowered, pattern) {
				policy.Reason = "dashboard.auth.password contains a well-known weak pattern — choose a real passphrase (16+ characters)."
				return policy, nil
			}
		}
	}
	policy.Assigned = 2
	policy.Values[2], err = networkSettingsScalar(document.root, "dashboard.control.enabled", node{value: false}, true)
	if err != nil {
		return DashboardPolicy{}, err
	}
	policy.Values[2] = normalizedBool(policy.Values[2])
	policy.Assigned = 3
	if policy.Values[2] == "true" && input.Password == "" {
		policy.Reason = "dashboard.control.enabled is true but dashboard.auth.password is empty. Config editing from the dashboard can change the payout wallet and run '" + input.Program + " apply' — it must sit behind a login. Set dashboard.auth.password and re-run."
		return policy, nil
	}
	if policy.Values[2] == "true" && policy.Values[0] == "true" && policy.Values[1] != "true" {
		policy.Reason = "dashboard.control.enabled is true on a published onion (dashboard.onion.enabled) but dashboard.onion.client_auth is false. A root-capable config-mutation channel must not sit behind only a brute-forceable password on an anonymously-reachable .onion. Set dashboard.onion.client_auth: true (the default) and re-run."
	}
	return policy, nil
}

func dashboardAuthDocument(raw []byte) (*Document, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return nil, ErrUnsupportedValidation
	}
	return document, nil
}

func dashboardAuthUsername(value string) bool {
	if len(value) < 1 || len(value) > 64 {
		return false
	}
	for index := 0; index < len(value); index++ {
		current := value[index]
		if !(current >= 'A' && current <= 'Z' || current >= 'a' && current <= 'z' || current >= '0' && current <= '9' || strings.IndexByte("._@-", current) >= 0) {
			return false
		}
	}
	return true
}

func dashboardAuthPassword(value string) (bool, bool) {
	for index := 0; index < len(value); index++ {
		if value[index] >= 0x80 {
			return false, false
		}
	}
	if len(value) < 8 || len(value) > 128 {
		return false, true
	}
	for index := 0; index < len(value); index++ {
		current := value[index]
		if current < 0x20 || current > 0x7e || current == '"' {
			return false, true
		}
	}
	return true, true
}

func dashboardPolicyASCII(value string) bool {
	for index := 0; index < len(value); index++ {
		if value[index] < 0x20 || value[index] > 0x7e {
			return false
		}
	}
	return true
}

func dashboardPolicyRepeated(value string) bool {
	for index := 1; index < len(value); index++ {
		if value[index] != value[0] {
			return false
		}
	}
	return true
}
