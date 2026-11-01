package config

import (
	"errors"
)

var ErrUnsupportedDashboard = errors.New("unsupported dashboard environment plan")

const (
	dashboardXVBEnabled = iota
	dashboardXVBTor
	dashboardXVBURL
	dashboardXVBDonor
	dashboardXVBDonationLevel
	dashboardTariRequired
	dashboardFailClosed
	dashboardHCPingURL
	dashboardXVBStandbySource
	dashboardCheckForUpdates
	dashboardWorkerAPIPort
	dashboardWorkerAPIAuth
	dashboardWorkerAPIToken
	dashboardWorkerAPITokensJSON
	dashboardTGEnabled
	dashboardTGToken
	dashboardTGChat
	dashboardTGCommands
	dashboardEventStart
	dashboardEventEnd              = dashboardEventStart + 27
	dashboardHashrateDropThreshold = dashboardEventEnd
	dashboardHashrateDropMinutes   = dashboardHashrateDropThreshold + 1
	dashboardTGSummaryTime         = dashboardHashrateDropMinutes + 1
	dashboardNotifyWebhooks        = dashboardTGSummaryTime + 1
	dashboardNTFYURL               = dashboardNotifyWebhooks + 1
	dashboardNTFYToken             = dashboardNTFYURL + 1
	dashboardNotifyTor             = dashboardNTFYToken + 1
	dashboardValueCount            = dashboardNotifyTor + 1
)

type DashboardInput struct {
	Platform     string
	TariMode     string
	MoneroWallet string
}

type DashboardPlan struct {
	values [dashboardValueCount]string
}

func (plan DashboardPlan) Values() []string {
	values := make([]string, len(plan.values))
	copy(values, plan.values[:])
	return values
}

func DeriveDashboard(raw, table []byte, input DashboardInput) (DashboardPlan, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return DashboardPlan{}, ErrUnsupportedDashboard
	}
	defaults, err := NewDefaults(table)
	if err != nil {
		return DashboardPlan{}, ErrUnsupportedDashboard
	}

	plan := DashboardPlan{}
	if err = deriveDashboardCore(&plan, document.root, defaults, raw, input); err != nil {
		return DashboardPlan{}, err
	}
	if err = deriveDashboardWorkers(&plan, document.root); err != nil {
		return DashboardPlan{}, err
	}
	if err = deriveDashboardAlerts(&plan, document.root); err != nil {
		return DashboardPlan{}, err
	}
	return plan, nil
}

func deriveDashboardCore(plan *DashboardPlan, root node, defaults *Defaults, raw []byte, input DashboardInput) error {
	value, err := dashboardDefault(defaults, ".xvb.enabled", raw, input.Platform)
	if err != nil {
		return err
	}
	plan.values[dashboardXVBEnabled] = value
	value, err = dashboardNullDefault(root, "xvb.tor", "true")
	if err != nil {
		return err
	}
	plan.values[dashboardXVBTor] = normalizedBool(value)
	if plan.values[dashboardXVBURL], err = dashboardAlternative(root, "xvb.url", ""); err != nil {
		return err
	}
	if plan.values[dashboardXVBURL] == "" {
		plan.values[dashboardXVBURL] = "na.xmrvsbeast.com:4247"
	}
	if plan.values[dashboardXVBDonor], err = dashboardAlternative(root, "xvb.donor_id", ""); err != nil {
		return err
	}
	switch plan.values[dashboardXVBDonor] {
	case "", "auto", "DYNAMIC_ID":
		if !dashboardASCII(input.MoneroWallet) {
			return ErrUnsupportedDashboard
		}
		plan.values[dashboardXVBDonor] = input.MoneroWallet
		if len(plan.values[dashboardXVBDonor]) > 8 {
			plan.values[dashboardXVBDonor] = plan.values[dashboardXVBDonor][:8]
		}
	}
	if plan.values[dashboardXVBDonationLevel], err = dashboardAlternative(root, "xvb.donation_level", ""); err != nil {
		return err
	}
	if plan.values[dashboardXVBDonationLevel] == "" {
		plan.values[dashboardXVBDonationLevel] = "auto"
	}
	if plan.values[dashboardTariRequired], err = dashboardDefault(defaults, ".dashboard.tari_required", raw, input.Platform); err != nil {
		return err
	}
	if input.TariMode == "off" {
		plan.values[dashboardTariRequired] = "false"
	}
	if value, err = dashboardNullDefault(root, "dashboard.fail_closed", "false"); err != nil {
		return err
	}
	plan.values[dashboardFailClosed] = normalizedBool(value)
	if plan.values[dashboardHCPingURL], err = dashboardAlternative(root, "healthchecks.ping_url", ""); err != nil {
		return err
	}
	if plan.values[dashboardXVBStandbySource], err = dashboardAlternative(root, "xvb.standby.source", ""); err != nil {
		return err
	}
	check, err := dashboardPath(root, "dashboard.check_for_updates")
	if err != nil {
		return err
	}
	plan.values[dashboardCheckForUpdates] = "true"
	if enabled, ok := check.value.(bool); ok && !enabled {
		plan.values[dashboardCheckForUpdates] = "false"
	}
	return nil
}

func dashboardDefault(defaults *Defaults, path string, raw []byte, platform string) (string, error) {
	rendered, err := defaults.Get(path, raw, platform)
	if err != nil || len(rendered) == 0 || rendered[len(rendered)-1] != '\n' {
		return "", ErrUnsupportedDashboard
	}
	value := string(rendered[:len(rendered)-1])
	if !dashboardSupportedString(value) {
		return "", ErrUnsupportedDashboard
	}
	return value, nil
}

func dashboardPath(root node, path string) (node, error) {
	value, err := getStringPath(root, path)
	if err != nil {
		return node{}, ErrUnsupportedDashboard
	}
	return value, nil
}

func dashboardAlternative(root node, path, fallback string) (string, error) {
	value, err := dashboardPath(root, path)
	if err != nil {
		return "", err
	}
	if isNull(value) || value.value == false {
		return fallback, nil
	}
	return dashboardScalar(value)
}

func dashboardNullDefault(root node, path, fallback string) (string, error) {
	value, err := dashboardPath(root, path)
	if err != nil {
		return "", err
	}
	if isNull(value) {
		return fallback, nil
	}
	return dashboardScalar(value)
}

func dashboardScalar(value node) (string, error) {
	if value.object != nil || value.array != nil || isNull(value) {
		return "", ErrUnsupportedDashboard
	}
	if text, ok := value.value.(string); ok {
		if !dashboardSupportedString(text) {
			return "", ErrUnsupportedDashboard
		}
		return text, nil
	}
	rendered, err := rawJQ(value)
	if err != nil || len(rendered) == 0 || rendered[len(rendered)-1] != '\n' {
		return "", ErrUnsupportedDashboard
	}
	return string(rendered[:len(rendered)-1]), nil
}

func dashboardSupportedString(value string) bool {
	for _, current := range value {
		if current <= 0x1f || current >= 0x7f && current <= 0x9f {
			return false
		}
	}
	return true
}

func dashboardASCII(value string) bool {
	for _, current := range []byte(value) {
		if current >= 0x80 {
			return false
		}
	}
	return true
}
