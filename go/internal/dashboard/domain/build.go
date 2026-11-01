package domain

import (
	"bytes"
	"encoding/json"
	"errors"
	"math"
	"strings"
)

const defaultPPLNSWindow = 2160

func Build(input Input) (map[string]any, error) {
	if math.IsNaN(input.Now) || math.IsInf(input.Now, 0) {
		return nil, errors.New("invalid domain clock")
	}
	data := input.LatestData
	if data == nil {
		data = map[string]any{}
	}
	xvb := input.XVBStats
	if xvb == nil {
		xvb = map[string]any{}
	}
	tiers, err := numericTiers(input.Tiers)
	if err != nil {
		return nil, err
	}
	p2pool1H, err := average(input.History, 3600, input.Now, "v_p2pool", true)
	if err != nil {
		return nil, err
	}
	p2pool24H, err := average(input.History, 86400, input.Now, "v_p2pool", true)
	if err != nil {
		return nil, err
	}
	p2pool30D, err := average(input.History, 30*86400, input.Now, "v_p2pool", true)
	if err != nil {
		return nil, err
	}
	xvbRouted1H, err := average(input.History, 3600, input.Now, "v_xvb", false)
	if err != nil {
		return nil, err
	}
	xvbRouted24H, err := average(input.History, 86400, input.Now, "v_xvb", false)
	if err != nil {
		return nil, err
	}
	total, err := number(rawOrZero(data, "total_live_h15"))
	if err != nil {
		return nil, err
	}
	xvb1H := rawOrZero(xvb, "avg_1h")
	xvb24H := rawOrZero(xvb, "avg_24h")
	xvb1HNumber, err := number(xvb1H)
	if err != nil {
		return nil, err
	}
	xvb24HNumber, err := number(xvb24H)
	if err != nil {
		return nil, err
	}
	currentTier, _ := tierInfo(math.Min(xvb1HNumber, xvb24HNumber), tiers)
	target, sustainable := targetThreshold(tiers, total, input.Config.DonationLevel, input.Config.MaxDonationFraction)
	targetTier, _ := tierInfo(target, tiers)
	level := strings.ToLower(strings.TrimSpace(input.Config.DonationLevel))
	lowWarning := input.Config.EnableXVB && level != "auto" && level != "highest" && target > 0 && !sustainable
	mode := any("P2POOL")
	if value, ok := xvb["current_mode"]; ok {
		mode = value
	}
	if !input.Config.EnableXVB {
		mode = "P2POOL (XvB Disabled)"
		currentTier = "Disabled"
		targetTier = "Disabled"
		lowWarning = false
	}
	stratum, err := object(data, "stratum")
	if err != nil {
		return nil, err
	}
	poolStats, err := object(data, "pool")
	if err != nil {
		return nil, err
	}
	p2p, err := object(poolStats, "p2p")
	if err != nil {
		return nil, err
	}
	pool, err := object(poolStats, "pool")
	if err != nil {
		return nil, err
	}
	network, err := object(data, "network")
	if err != nil {
		return nil, err
	}
	poolType := any("Main")
	if value, ok := p2p["type"]; ok {
		poolType = value
	}
	blockTime := 10
	if poolTypeString, ok := poolType.(string); ok && poolTypeString == "Nano" {
		blockTime = 30
	}
	pplnsWindow := any(defaultPPLNSWindow)
	if value, ok := pool["pplns_window"]; ok {
		pplnsWindow = value
	}
	shares, err := rows(data, "shares")
	if err != nil {
		return nil, err
	}
	sharesInWindow, ownWeight, err := shareWindow(shares, pplnsWindow, blockTime, input.Now)
	if err != nil {
		return nil, err
	}
	poolDifficulty := rawOrZero(pool, "difficulty")
	difficulty, err := number(poolDifficulty)
	if err != nil {
		return nil, err
	}
	windowNumber, err := number(pplnsWindow)
	if err != nil {
		return nil, err
	}
	expectedShareSec := 0.0
	luckPct := 0.0
	if difficulty > 0 && p2pool1H > 0 && windowNumber > 0 {
		expectedShareSec = difficulty / p2pool1H
		expectedShares := p2pool1H * (windowNumber * float64(blockTime)) / difficulty
		luckPct = float64(sharesInWindow) / expectedShares * 100
	}
	workers, err := rows(data, "workers")
	if err != nil {
		return nil, err
	}
	workersOnline := 0
	for _, raw := range workers {
		worker, ok := raw.(map[string]any)
		if !ok {
			return nil, errors.New("invalid worker")
		}
		if status, ok := worker["status"].(string); ok && status == "online" {
			workersOnline++
		}
	}
	moneroSync, err := object(data, "monero_sync")
	if err != nil {
		return nil, err
	}
	tariSync, err := object(data, "tari_sync")
	if err != nil {
		return nil, err
	}
	monero, err := syncMetric(moneroSync)
	if err != nil {
		return nil, err
	}
	tari, err := syncMetric(tariSync)
	if err != nil {
		return nil, err
	}
	tariData, err := object(data, "tari")
	if err != nil {
		return nil, err
	}
	lastUpdate := rawOrZero(xvb, "last_update")
	lastUpdateNumber, err := number(lastUpdate)
	if err != nil {
		return nil, err
	}
	xvbStale := input.Config.EnableXVB && lastUpdateNumber > 0 && input.Now-lastUpdateNumber > input.Config.XVBStatsStaleAfter
	moneroLocal := input.Config.MoneroNodeHost == input.Config.LocalMoneroHost
	if input.Config.MoneroLocal != nil {
		moneroLocal = *input.Config.MoneroLocal
	}
	moneroMode := "Unknown"
	if input.Config.MoneroNodeHost == input.Config.LocalMoneroHost {
		moneroMode = "Full"
		if input.Config.MoneroPrune {
			moneroMode = "Pruned"
		}
	}
	var tariLocal any
	if input.Config.TariMode != "off" {
		tariLocal = input.Config.TariMode == "local"
	}
	if len(input.Config.TariLocal) != 0 {
		trimmed := bytes.TrimSpace(input.Config.TariLocal)
		if bytes.Equal(trimmed, []byte("null")) {
			tariLocal = nil
		} else {
			var value bool
			if err := json.Unmarshal(trimmed, &value); err != nil {
				return nil, errors.New("invalid Tari locality")
			}
			tariLocal = value
		}
	}
	return map[string]any{
		"total_h15": rawOrZero(data, "total_live_h15"), "p2pool_1h": PythonFloat(p2pool1H),
		"p2pool_24h": PythonFloat(p2pool24H), "xvb_1h": xvb1H, "xvb_24h": xvb24H,
		"xvb_routed_1h": PythonFloat(xvbRouted1H), "xvb_routed_24h": PythonFloat(xvbRouted24H),
		"stratum_h15": rawOrZero(stratum, "hashrate_15m"), "stratum_h1h": rawOrZero(stratum, "hashrate_1h"),
		"stratum_h24h": rawOrZero(stratum, "hashrate_24h"), "mode": mode, "xvb_enabled": input.Config.EnableXVB,
		"current_tier": currentTier, "target_tier": targetTier, "target_threshold": PythonFloat(target),
		"target_sustainable": sustainable, "low_hr_warning": lowWarning,
		"xvb_fail_count": rawOrZero(xvb, "fail_count"), "xvb_last_update": lastUpdate,
		"workers_online": workersOnline, "workers_total": len(workers), "shares_in_window": sharesInWindow,
		"pplns_window": pplnsWindow, "block_time": blockTime, "pool_type": poolType,
		"pool_hashrate": rawOrZero(pool, "hashrate"), "pool_difficulty": poolDifficulty,
		"network_difficulty": rawOrZero(network, "difficulty"), "network_height": rawOrZero(network, "height"),
		"global_syncing": truthy(data["global_sync"]), "monero": monero, "tari": tari,
		"monero_mode": moneroMode, "tari_mining": truthy(tariData["active"]),
		"xvb_registered_at":      rawOrZero(xvb, "registered_at"),
		"xvb_registration_state": stringOrEmpty(xvb["registration_state"]), "xvb_stale": xvbStale,
		"own_pplns_weight": ownWeight, "last_block_ts": rawOrZero(pool, "last_block_ts"),
		"expected_share_sec": PythonFloat(expectedShareSec), "luck_pct": PythonFloat(luckPct),
		"tari_difficulty": rawOrZero(tariData, "difficulty"), "tari_reward": rawOrZero(tariData, "reward"),
		"p2pool_30d": PythonFloat(p2pool30D), "monero_local": moneroLocal, "tari_local": tariLocal,
	}, nil
}

func syncMetric(sync map[string]any) (map[string]any, error) {
	percent := rawOrZero(sync, "percent")
	current := rawOrZero(sync, "current")
	target := rawOrZero(sync, "target")
	targetNumber, err := number(target)
	if err != nil {
		return nil, err
	}
	percentNumber, err := number(percent)
	if err != nil {
		return nil, err
	}
	remaining, err := subtract(target, current)
	if err != nil {
		return nil, err
	}
	hasTarget := targetNumber > 0
	isSyncing := true
	if value, ok := sync["is_syncing"]; ok {
		isSyncing = truthy(value)
	}
	done := truthy(sync["reachable"]) && !isSyncing || hasTarget && percentNumber >= 100
	return map[string]any{
		"percent": percent, "current": current, "target": target, "remaining": remaining,
		"has_target": hasTarget, "done": done, "down": truthy(sync["down"]),
	}, nil
}

func stringOrEmpty(value any) any {
	if !truthy(value) {
		return ""
	}
	return value
}
