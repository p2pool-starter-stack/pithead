package config

import (
	"encoding/json"
	"strings"
)

var dashboardEventNames = [...]string{
	"node_down",
	"node_recovered",
	"worker_offline",
	"worker_recovered",
	"worker_joined",
	"worker_left",
	"sync_finished",
	"disk_space",
	"db_unhealthy",
	"db_reset",
	"xvb_no_share",
	"clearnet_exposed",
	"xvb_registration",
	"new_release",
	"stack_online",
	"daily_summary",
	"hashrate_low",
	"hashrate_loss",
	"hugepages",
	"low_ram",
	"wallet_changed",
	"high_reject_rate",
	"block_found",
	"payout_found",
	"payout_confirmed",
	"container_unhealthy",
	"raffle_win",
}

func deriveDashboardAlerts(plan *DashboardPlan, root node) error {
	var err error
	if plan.values[dashboardTGEnabled], err = dashboardTostring(root, "telegram.enabled", "false"); err != nil {
		return err
	}
	if plan.values[dashboardTGToken], err = dashboardAlternative(root, "telegram.bot_token", ""); err != nil {
		return err
	}
	if plan.values[dashboardTGChat], err = dashboardAlternative(root, "telegram.chat_id", ""); err != nil {
		return err
	}
	if plan.values[dashboardTGCommands], err = dashboardTostring(root, "telegram.commands.enabled", "false"); err != nil {
		return err
	}
	for index, name := range dashboardEventNames {
		value, eventErr := dashboardTostring(root, "telegram.events."+name, "true")
		if eventErr != nil {
			return eventErr
		}
		plan.values[dashboardEventStart+index] = value
	}
	if plan.values[dashboardHashrateDropThreshold], err = dashboardAlternative(root, "dashboard.hashrate_drop_threshold", "50"); err != nil {
		return err
	}
	if plan.values[dashboardHashrateDropMinutes], err = dashboardAlternative(root, "dashboard.hashrate_drop_minutes", "10"); err != nil {
		return err
	}
	if plan.values[dashboardTGSummaryTime], err = dashboardAlternative(root, "telegram.daily_summary_time", "08:00"); err != nil {
		return err
	}
	if plan.values[dashboardNotifyWebhooks], err = dashboardWebhookList(root); err != nil {
		return err
	}
	if plan.values[dashboardNTFYURL], err = dashboardAlternative(root, "notifications.ntfy.url", ""); err != nil {
		return err
	}
	if plan.values[dashboardNTFYToken], err = dashboardAlternative(root, "notifications.ntfy.token", ""); err != nil {
		return err
	}
	plan.values[dashboardNotifyTor], err = dashboardTostring(root, "notifications.tor", "true")
	return err
}

func dashboardTostring(root node, path, fallback string) (string, error) {
	value, err := dashboardPath(root, path)
	if err != nil {
		return "", err
	}
	if isNull(value) {
		return fallback, nil
	}
	return dashboardScalar(value)
}

func dashboardWebhookList(root node) (string, error) {
	value, err := dashboardAlternativeNode(root, "notifications.webhooks", node{array: []node{}})
	if err != nil || value.array == nil {
		return "", ErrUnsupportedDashboard
	}
	parts := make([]string, 0, len(value.array))
	for _, item := range value.array {
		switch typed := item.value.(type) {
		case nil:
			if item.object != nil || item.array != nil {
				return "", ErrUnsupportedDashboard
			}
			parts = append(parts, "")
		case string:
			if !dashboardSupportedString(typed) {
				return "", ErrUnsupportedDashboard
			}
			parts = append(parts, typed)
		case bool:
			if typed {
				parts = append(parts, "true")
			} else {
				parts = append(parts, "false")
			}
		case json.Number:
			text, scalarErr := dashboardScalar(item)
			if scalarErr != nil {
				return "", scalarErr
			}
			parts = append(parts, text)
		default:
			return "", ErrUnsupportedDashboard
		}
	}
	return strings.Join(parts, " "), nil
}
