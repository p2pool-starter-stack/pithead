package badges

import (
	"errors"
	"strings"
)

const (
	lowHRTitle       = "Your hashrate can't sustain the selected XvB donation tier; donation will fall short of it."
	notEligibleTitle = "You have no share in the P2Pool PPLNS window, so you're not eligible to collect an XvB raffle win (what XvB calls being a \"VIP\"). If you win a round you're skipped and take a fail (removed from the raffle after the 3rd) — regardless of your donation tier. Keep enough hashrate on P2Pool to keep landing shares."
	registeredTitle  = "This wallet is auto-registered with the XMRvsBeast raffle. Re-registration runs periodically; no manual signup is needed."
	invalidTitle     = "The XvB raffle endpoint rejected your wallet as invalid, so you won't be entered. The raffle needs a standard primary Monero address (starts with 4). Check MONERO_WALLET_ADDRESS."
	failingTitle     = "XvB raffle registration keeps failing despite a PPLNS share — the endpoint may be unreachable or erroring. Check the dashboard logs and the XvB egress (Tor) path."
)

type settings struct {
	diskWarn     float64
	diskCritical float64
	lowRAMAvail  float64
	lowRAMFloor  float64
	moneroLocal  bool
}

func buildBadges(request Request) (any, error) {
	values, err := arguments(request.Args, 6)
	if err != nil {
		return nil, err
	}
	data, err := object(values[0])
	if err != nil {
		return nil, err
	}
	metrics, err := object(values[1])
	if err != nil {
		return nil, err
	}
	modeVariant, ok := values[2].(string)
	if !ok {
		return nil, errors.New("expected mode variant string")
	}
	dbHealthy, ok := values[3].(bool)
	if !ok {
		return nil, errors.New("expected db healthy bool")
	}
	var wallet map[string]any
	if values[4] != nil {
		wallet, err = object(values[4])
		if err != nil {
			return nil, err
		}
	}
	config, err := parseSettings(values[5])
	if err != nil {
		return nil, err
	}
	return badgeList(data, metrics, modeVariant, dbHealthy, wallet, config, request.Zone)
}

func parseSettings(value any) (settings, error) {
	object, err := object(value)
	if err != nil {
		return settings{}, err
	}
	result := settings{}
	if result.diskWarn, err = requiredNumber(object, "disk_warn_percent"); err != nil {
		return settings{}, err
	}
	if result.diskCritical, err = requiredNumber(object, "disk_critical_percent"); err != nil {
		return settings{}, err
	}
	if result.lowRAMAvail, err = requiredNumber(object, "low_ram_available_gb"); err != nil {
		return settings{}, err
	}
	if result.lowRAMFloor, err = requiredNumber(object, "low_ram_floor_gb"); err != nil {
		return settings{}, err
	}
	if result.moneroLocal, err = requiredBool(object, "monero_local"); err != nil {
		return settings{}, err
	}
	if value, found := object["tari_local"]; !found {
		return settings{}, errors.New("missing tari_local")
	} else if value != nil {
		if _, ok := value.(bool); !ok {
			return settings{}, errors.New("expected bool tari_local")
		}
	}
	return result, nil
}

func badge(text, variant string, title ...string) map[string]any {
	result := map[string]any{"text": text, "variant": variant}
	if len(title) != 0 {
		result["title"] = title[0]
	}
	return result
}

func badgeList(data, metrics map[string]any, modeVariant string, dbHealthy bool, wallet map[string]any, config settings, zone string) ([]any, error) {
	badges := make([]any, 0, 16)
	if wallet != nil && len(wallet) != 0 {
		old8, err := requiredString(wallet, "old8")
		if err != nil {
			return nil, err
		}
		new8, err := requiredString(wallet, "new8")
		if err != nil {
			return nil, err
		}
		timestamp, err := requiredNumber(wallet, "ts")
		if err != nil {
			return nil, err
		}
		formattedTime, err := absoluteTime(timestamp, zone)
		if err != nil {
			return nil, err
		}
		badges = append(badges, badge("⚠ Payout wallet changed", "warn", old8+"… → "+new8+"… at "+formattedTime))
	}
	if !dbHealthy {
		badges = append(badges, badge("⚠ DB write failing", "bad", "The dashboard can't persist to its database — hashrate history, shares, and stats will be lost on restart. Check disk space and permissions on the dashboard data directory."))
	}
	globalSyncing, err := requiredBool(metrics, "global_syncing")
	if err != nil {
		return nil, err
	}
	if globalSyncing {
		badges = append(badges, badge("Syncing...", "warn"))
	} else {
		mode, err := requiredString(metrics, "mode")
		if err != nil {
			return nil, err
		}
		pool, err := requiredString(metrics, "pool_type")
		if err != nil {
			return nil, err
		}
		badges = append(badges, badge(mode, modeVariant), badge("P2Pool "+pool, "outline"))
		lowHashrate, err := requiredBool(metrics, "low_hr_warning")
		if err != nil {
			return nil, err
		}
		if lowHashrate {
			badges = append(badges, badge("⚠ Hashrate low for tier", "warn", lowHRTitle))
		}
		xvbEnabled, err := requiredBool(metrics, "xvb_enabled")
		if err != nil {
			return nil, err
		}
		shares, err := requiredNumber(metrics, "shares_in_window")
		if err != nil {
			return nil, err
		}
		if xvbEnabled && shares == 0 {
			badges = append(badges, badge("⚠ No PPLNS share — XvB wins skipped", "warn", notEligibleTitle))
		}
		if xvbEnabled {
			state, err := requiredString(metrics, "xvb_registration_state")
			if err != nil {
				return nil, err
			}
			registeredAt, err := requiredNumber(metrics, "xvb_registered_at")
			if err != nil {
				return nil, err
			}
			switch {
			case state == "invalid":
				badges = append(badges, badge("⚠ XvB wallet rejected", "bad", invalidTitle))
			case state == "failing":
				badges = append(badges, badge("⚠ XvB registration failing", "bad", failingTitle))
			case registeredAt > 0:
				badges = append(badges, badge("XvB raffle ✓", "outline", registeredTitle))
			}
		}
	}
	return appendInfrastructureBadges(badges, data, metrics, config)
}

func appendInfrastructureBadges(badges []any, data, metrics map[string]any, config settings) ([]any, error) {
	monero, err := object(member(metrics, "monero", nil))
	if err != nil {
		return nil, err
	}
	moneroDown, err := requiredBool(monero, "down")
	if err != nil {
		return nil, err
	}
	if moneroDown {
		badges = append(badges, badge("monerod DOWN", "bad"))
	}
	if config.moneroLocal && !moneroDown {
		health, err := nestedObject(data, "monero_sync", "health")
		if err != nil {
			return nil, err
		}
		if member(health, "level", "") == "red" {
			title, err := healthTitle(health)
			if err != nil {
				return nil, err
			}
			badges = append(badges, badge("Monero chain unhealthy", "bad", title))
		}
	}
	tari, err := object(member(metrics, "tari", nil))
	if err != nil {
		return nil, err
	}
	tariDown, err := requiredBool(tari, "down")
	if err != nil {
		return nil, err
	}
	if tariDown {
		badges = append(badges, badge("Tari DOWN", "bad"))
	}
	if truthy(member(data, "workers_rejected", nil)) {
		badges = append(badges, badge("Workers rejected", "bad", "Workers rejected so they fail over to their backup pools"))
	}
	if truthy(member(data, "miner_held", nil)) {
		badges = append(badges, badge("Miner held (sync)", "warn", "p2pool and xmrig-proxy are held until the required chains finish syncing"))
	}
	if truthy(member(data, "fail_closed_held", nil)) {
		badges = append(badges, badge("Miner held (fail-closed)", "bad", "dashboard.fail_closed is on and an unrecoverable health failure is holding p2pool and xmrig-proxy until it clears"))
	}
	if truthy(member(data, "tari_syncing_passive", nil)) {
		percentRaw, ok := tari["percent"]
		if !ok {
			return nil, errors.New("missing percent")
		}
		percent, err := number(percentRaw)
		if err != nil {
			return nil, err
		}
		label := "Tari syncing"
		if percent > 0 {
			formatted, err := pythonString(percentRaw)
			if err != nil {
				return nil, err
			}
			label += " " + formatted + "%"
		}
		badges = append(badges, badge(label, "warn", "Tari is still syncing — merge-mining resumes when it catches up; Monero mining continues"))
	}
	mode, err := requiredString(metrics, "monero_mode")
	if err != nil {
		return nil, err
	}
	if mode == "Pruned" {
		badges = append(badges, badge("XMR Pruned", "outline", "Monero blockchain is pruned"))
	} else if mode == "Full" {
		badges = append(badges, badge("XMR Full", "outline", "Monero blockchain is full (not pruned)"))
	}
	return appendSystemBadges(badges, data, config)
}

func nestedObject(value map[string]any, keys ...string) (map[string]any, error) {
	current := value
	for _, key := range keys {
		found := member(current, key, map[string]any{})
		if found == nil {
			return map[string]any{}, nil
		}
		next, err := object(found)
		if err != nil {
			return nil, err
		}
		current = next
	}
	return current, nil
}

func healthTitle(health map[string]any) (string, error) {
	values := make([]string, 0)
	reasons := member(health, "reasons", []any{})
	if reasons != nil {
		items, ok := reasons.([]any)
		if !ok {
			return "", errors.New("expected health reasons array")
		}
		for _, item := range items {
			text, ok := item.(string)
			if !ok {
				return "", errors.New("expected health reason string")
			}
			values = append(values, text)
		}
	}
	advice := member(health, "advice", "")
	if !truthy(advice) {
		advice = ""
	}
	text, ok := advice.(string)
	if !ok {
		return "", errors.New("expected health advice string")
	}
	return strings.Join(append(values, text), "; "), nil
}
