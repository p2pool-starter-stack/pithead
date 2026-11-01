package overview

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"strings"
)

func buildPoolNetwork(request Request) (any, error) {
	values, err := arguments(request.Args, 3)
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
	for _, key := range []string{
		"stratum_h15", "stratum_h1h", "stratum_h24h", "pool_type", "pool_hashrate",
		"pool_difficulty", "network_difficulty", "network_height", "pplns_window",
		"block_time", "shares_in_window",
	} {
		if _, err := required(metrics, key); err != nil {
			return nil, err
		}
	}
	stratum, err := optionalObject(data, "stratum")
	if err != nil {
		return nil, err
	}
	poolStats, err := optionalObject(data, "pool")
	if err != nil {
		return nil, err
	}
	localPool, err := optionalObject(poolStats, "pool")
	if err != nil {
		return nil, err
	}
	p2p, err := optionalObject(poolStats, "p2p")
	if err != nil {
		return nil, err
	}
	network, err := optionalObject(data, "network")
	if err != nil {
		return nil, err
	}
	zone, err := location(request.Zone)
	if err != nil {
		return nil, err
	}
	wallet, ok := member(stratum, "wallet", "Unknown").(string)
	if !ok {
		return nil, errors.New("invalid stratum wallet")
	}
	lastBlock := "Never"
	lastBlockValue := member(localPool, "last_block_ts", 0)
	if truthy(lastBlockValue) {
		stamp, err := number(lastBlockValue)
		if err != nil || math.IsNaN(request.Now) || math.IsInf(request.Now, 0) {
			return nil, errors.New("invalid last block time")
		}
		lastBlock = formatDuration(request.Now-stamp) + " ago"
	}
	poolDifficulty, err := metricNumber(metrics, "pool_difficulty")
	if err != nil {
		return nil, err
	}
	networkDifficulty, err := metricNumber(metrics, "network_difficulty")
	if err != nil {
		return nil, err
	}
	pplnsWindow, err := required(metrics, "pplns_window")
	if err != nil {
		return nil, err
	}
	blockTime, err := required(metrics, "block_time")
	if err != nil {
		return nil, err
	}
	pplnsDuration, err := multiply(pplnsWindow, blockTime)
	if err != nil {
		return nil, err
	}
	hash := pythonString(member(network, "hash", "N/A"))
	effort, err := percent(member(stratum, "current_effort", 0), 1)
	if err != nil {
		return nil, err
	}
	rewardPercent, err := percent(member(stratum, "block_reward_share_percent", 0), 4)
	if err != nil {
		return nil, err
	}
	reward, err := scaled(member(network, "reward", 0), 1e12, 4, " XMR")
	if err != nil {
		return nil, err
	}
	sharesOK, err := positive(metrics["shares_in_window"])
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"stratum": map[string]any{
			"h15": formatHashrate(metrics["stratum_h15"]), "h1h": formatHashrate(metrics["stratum_h1h"]),
			"h24h":   formatHashrate(metrics["stratum_h24h"]),
			"shares": pythonString(member(stratum, "shares_found", 0)) + " / " + pythonString(member(stratum, "shares_failed", 0)),
			"effort": effort, "total_shares": member(stratum, "total_stratum_shares", 0),
			"reward_pct": rewardPercent, "conns": member(stratum, "connections", 0),
			"last_share": formatTimeAbs(member(stratum, "last_share_found_time", 0), zone), "total_hashes": member(stratum, "total_hashes", 0),
			"wallet": wallet, "wallet_short": shortened(wallet, 8, 16),
		},
		"pool": map[string]any{
			"type": metrics["pool_type"], "syncing": member(localPool, "syncing", false), "sidechain_height": member(localPool, "sidechain_height", 0),
			"diff": fmt.Sprintf("%.2f M", poolDifficulty/1e6), "hr": formatHashrate(metrics["pool_hashrate"]), "total_hashes": member(localPool, "total_hashes", 0),
			"miners": member(localPool, "miners", 0), "pplns_win": pythonString(pplnsWindow) + " (" + formatDuration(pplnsDuration) + ")",
			"pplns_wgt": member(localPool, "pplns_weight", 0), "blocks": member(localPool, "blocks_found", 0), "last_blk": lastBlock,
			"peers": pythonString(member(p2p, "out_peers", 0)) + " / " + pythonString(member(p2p, "in_peers", 0)), "uptime": formatDuration(member(p2p, "uptime", 0)),
		},
		"network": map[string]any{
			"height": metrics["network_height"], "reward": reward,
			"diff": fmt.Sprintf("%.2f G", networkDifficulty/1e9), "hash": shortened(hash, 8, 20), "ts": formatTimeAbs(member(network, "timestamp", 0), zone),
		},
		"monero":        values[2],
		"shares_window": map[string]any{"count": metrics["shares_in_window"], "ok": sharesOK},
	}, nil
}

func optionalObject(values map[string]any, key string) (map[string]any, error) {
	value := member(values, key, map[string]any{})
	return object(value)
}

func metricNumber(metrics map[string]any, key string) (float64, error) {
	value, err := required(metrics, key)
	if err != nil {
		return 0, err
	}
	return number(value)
}

func multiply(left, right any) (any, error) {
	leftNumber, leftOK := left.(json.Number)
	rightNumber, rightOK := right.(json.Number)
	if leftOK && rightOK && !strings.ContainsAny(leftNumber.String()+rightNumber.String(), ".eE") {
		leftInteger, leftSet := new(big.Int).SetString(leftNumber.String(), 10)
		rightInteger, rightSet := new(big.Int).SetString(rightNumber.String(), 10)
		if leftSet && rightSet {
			return json.Number(new(big.Int).Mul(leftInteger, rightInteger).String()), nil
		}
	}
	a, err := number(left)
	if err != nil {
		return 0, err
	}
	b, err := number(right)
	if err != nil {
		return 0, err
	}
	return a * b, nil
}

func percent(value any, places int) (string, error) {
	n, err := number(value)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%.*f%%", places, n), nil
}

func scaled(value any, scale float64, places int, suffix string) (string, error) {
	n, err := number(value)
	if err != nil {
		return "", err
	}
	return fmt.Sprintf("%.*f%s", places, n/scale, suffix), nil
}

func positive(value any) (bool, error) {
	if raw, ok := value.(json.Number); ok {
		if exact, set := new(big.Rat).SetString(raw.String()); set {
			return exact.Sign() > 0, nil
		}
	}
	n, err := number(value)
	if err != nil {
		return false, err
	}
	return n > 0, nil
}
