package overview

import (
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"math/big"
	"time"
)

const earningsDisclaimer = "Estimated XMR from P2Pool mining only — excludes XvB donations (donated hashrate earns no " +
	"P2Pool payout). Tari is merge-mined SOLO by the same hashrate: you get the whole block reward " +
	"at once when your hashrate finds a Tari block — roughly every 'time to Tari block' shown — so " +
	"the per-day XTM figure is a long-run average, not steady income. Expected values only; mining " +
	"is variance-heavy, so real payouts swing well above and below these figures. Estimates, " +
	"not guarantees."

func buildEarnings(request Request) (any, error) {
	values, err := arguments(request.Args, 5)
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
	network, err := falseOrObject(member(data, "network", map[string]any{}))
	if err != nil {
		return nil, err
	}
	rewardValue := member(network, "reward", 0)
	if !truthy(rewardValue) {
		rewardValue = 0
	}
	networkDifficulty, err := required(metrics, "network_difficulty")
	if err != nil {
		return nil, err
	}
	coefficient, err := xmrPerHSDay(rewardValue, networkDifficulty)
	if err != nil {
		return nil, err
	}
	p2poolHR, err := required(metrics, "p2pool_1h")
	if err != nil {
		return nil, err
	}
	tariReward, err := required(metrics, "tari_reward")
	if err != nil {
		return nil, err
	}
	tariDifficulty, err := required(metrics, "tari_difficulty")
	if err != nil {
		return nil, err
	}
	tariCoefficient, err := xtmPerHSDay(tariReward, tariDifficulty)
	if err != nil {
		return nil, err
	}
	tariSeconds, err := tariSecondsToBlockPerHS(tariDifficulty)
	if err != nil {
		return nil, err
	}
	tariMining, err := required(metrics, "tari_mining")
	if err != nil {
		return nil, err
	}
	poolDifficulty, err := required(metrics, "pool_difficulty")
	if err != nil {
		return nil, err
	}
	wallets, err := falseOrObject(member(data, "payout_wallet", map[string]any{}))
	if err != nil {
		return nil, err
	}
	zone := time.Local
	if values[2] != nil || values[3] != nil {
		zone, err = location(request.Zone)
		if err != nil {
			return nil, err
		}
	}
	confirmed, err := confirmedPayoutsSummary(values[2], request.Now, zone, atomicPerXMR, "xmr", member(wallets, "monero", nil))
	if err != nil {
		return nil, err
	}
	tariConfirmed, err := confirmedPayoutsSummary(values[3], request.Now, zone, microPerXTM, "xtm", member(wallets, "tari", nil))
	if err != nil {
		return nil, err
	}
	reward, err := pythonDivide(rewardValue, float64(atomicPerXMR))
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"available": coefficient > 0, "p2pool_hr": p2poolHR, "p2pool_hr_str": formatHashrate(p2poolHR),
		"coeff_day": coefficient, "tari_available": tariCoefficient > 0 && truthy(tariMining),
		"tari_coeff_day": tariCoefficient, "tari_difficulty": tariSeconds, "tari_reward": tariReward,
		"xvb_day": values[4], "pool_difficulty": poolDifficulty,
		"block_reward": fmt.Sprintf("%.4f XMR", reward), "disclaimer": earningsDisclaimer,
		"confirmed": confirmed, "tari_confirmed": tariConfirmed,
	}, nil
}

func buildEarningsVsActual(request Request) (any, error) {
	values, err := arguments(request.Args, 5)
	if err != nil {
		return nil, err
	}
	metrics, err := object(values[0])
	if err != nil {
		return nil, err
	}
	earnings, err := object(values[1])
	if err != nil {
		return nil, err
	}
	raffleWins, err := nullableArray(values[2])
	if err != nil {
		return nil, err
	}
	coefficient, err := requiredFinite(earnings, "coeff_day")
	if err != nil {
		return nil, err
	}
	p2pool30d, err := requiredFinite(metrics, "p2pool_30d")
	if err != nil {
		return nil, err
	}
	expectedP2Pool := coefficient * p2pool30d * 30
	xvbEnabledValue, err := required(metrics, "xvb_enabled")
	if err != nil {
		return nil, err
	}
	xvbDayValue, err := required(earnings, "xvb_day")
	if err != nil {
		return nil, err
	}
	xvbDay := 0.0
	if truthy(xvbDayValue) {
		xvbDay, err = number(xvbDayValue)
		if err != nil {
			return nil, err
		}
	}
	expectedXVB := 0.0
	if truthy(xvbEnabledValue) {
		expectedXVB = math.Max(0, xvbDay) * 30
	}
	realization, measured, err := realizationValues(values[4], expectedXVB)
	if err != nil {
		return nil, err
	}
	if measured {
		expectedXVB *= realization.fraction
	}
	confirmed, err := requiredObject(earnings, "confirmed")
	if err != nil {
		return nil, err
	}
	xmrEnabled := truthy(member(confirmed, "enabled", nil))
	xmrActual := any(nil)
	if xmrEnabled {
		xmrActual = member(confirmed, "xmr_30d", nil)
	}
	xmrPartial, err := partialWindow(confirmed, "30d")
	if err != nil {
		return nil, err
	}
	xmr := map[string]any{
		"available": expectedP2Pool > 0, "expected_30d": expectedP2Pool + expectedXVB,
		"includes_xvb": expectedXVB > 0, "xvb_realization_pct": nil, "xvb_wins_measured": nil,
		"enabled": xmrEnabled, "actual_30d": xmrActual, "partial": xmrPartial, "pct": nil,
	}
	if measured {
		xmr["xvb_realization_pct"], err = pythonRound(realization.fraction * 100)
		if err != nil {
			return nil, err
		}
		xmr["xvb_wins_measured"] = realization.count
	}
	if expectedP2Pool > 0 && xmrEnabled {
		actual := 0.0
		if truthy(xmrActual) {
			actual, err = number(xmrActual)
			if err != nil {
				return nil, err
			}
		}
		percentage, err := pythonRound(actual / (expectedP2Pool + expectedXVB) * 100)
		if err != nil {
			return nil, err
		}
		if roundedAtMost(percentage, 999) {
			xmr["pct"] = percentage
		}
	}
	tari, err := earningsTari(metrics, earnings, p2pool30d)
	if err != nil {
		return nil, err
	}
	xvb, err := earningsXVB(raffleWins, request.Now, xvbEnabledValue, values[3])
	if err != nil {
		return nil, err
	}
	return map[string]any{"xmr": xmr, "tari": tari, "xvb": xvb}, nil
}

func earningsTari(metrics, earnings map[string]any, p2pool30d float64) (map[string]any, error) {
	tariMining, err := required(metrics, "tari_mining")
	if err != nil {
		return nil, err
	}
	difficulty, err := requiredFinite(metrics, "tari_difficulty")
	if err != nil {
		return nil, err
	}
	expected := 0.0
	if truthy(tariMining) && difficulty > 0 {
		expected = p2pool30d * 30 * secondsDay / difficulty
	}
	confirmed, err := requiredObject(earnings, "tari_confirmed")
	if err != nil {
		return nil, err
	}
	enabled := truthy(member(confirmed, "enabled", nil))
	partial, err := partialWindow(confirmed, "30d")
	if err != nil {
		return nil, err
	}
	local, err := required(metrics, "tari_local")
	if err != nil {
		return nil, err
	}
	result := map[string]any{
		"available": expected > 0, "expected_blocks_30d": expected, "enabled": enabled,
		"blocks_30d": nil, "xtm_30d": nil, "partial": partial, "is_local": local,
	}
	if enabled {
		result["blocks_30d"] = member(confirmed, "n_30d", nil)
		result["xtm_30d"] = member(confirmed, "xtm_30d", nil)
	}
	return result, nil
}

func earningsXVB(wins []any, now float64, enabledValue, expectedValue any) (map[string]any, error) {
	stamps := make([]float64, 0, len(wins))
	for _, value := range wins {
		win, err := object(value)
		if err != nil {
			return nil, err
		}
		stampValue := member(win, "ts", 0)
		if !truthy(stampValue) {
			stampValue = 0
		}
		stamp, err := number(stampValue)
		if err != nil {
			return nil, err
		}
		stamps = append(stamps, stamp)
	}
	wins30d := 0
	for _, stamp := range stamps {
		if stamp >= now-30*secondsDay {
			wins30d++
		}
	}
	_, last := extrema(stamps)
	expected := any(nil)
	if truthy(expectedValue) {
		n, err := number(expectedValue)
		if err != nil {
			return nil, err
		}
		expected = n * 30
	}
	return map[string]any{
		"enabled": truthy(enabledValue), "wins_30d": wins30d, "last_win_ts": last,
		"expected_wins_30d": expected,
	}, nil
}

type realizationValue struct {
	fraction float64
	count    any
}

func realizationValues(value any, expected float64) (realizationValue, bool, error) {
	var result realizationValue
	if !truthy(value) || expected <= 0 {
		return result, false, nil
	}
	values, err := array(value)
	if err != nil || len(values) != 2 {
		return result, false, errors.New("invalid realization")
	}
	fraction, err := number(values[0])
	if err != nil {
		return result, false, err
	}
	result.fraction, result.count = fraction, values[1]
	return result, true, nil
}

func requiredFinite(values map[string]any, key string) (float64, error) {
	value, err := required(values, key)
	if err != nil {
		return 0, err
	}
	return number(value)
}

func requiredObject(values map[string]any, key string) (map[string]any, error) {
	value, err := required(values, key)
	if err != nil {
		return nil, err
	}
	return object(value)
}

func falseOrObject(value any) (map[string]any, error) {
	if !truthy(value) {
		return map[string]any{}, nil
	}
	return object(value)
}

func nullableArray(value any) ([]any, error) {
	if !truthy(value) {
		return []any{}, nil
	}
	return array(value)
}

func partialWindow(summary map[string]any, window string) (bool, error) {
	value := member(summary, "partial", nil)
	if !truthy(value) {
		return false, nil
	}
	partial, err := object(value)
	if err != nil {
		return false, err
	}
	return truthy(member(partial, window, nil)), nil
}

func pythonRound(value float64) (any, error) {
	if math.IsNaN(value) || math.IsInf(value, 0) {
		return nil, errors.New("invalid rounded value")
	}
	rounded := math.RoundToEven(value)
	if rounded < float64(math.MaxInt64) && rounded > float64(math.MinInt64) {
		return int64(rounded), nil
	}
	integer, _ := new(big.Float).SetFloat64(rounded).Int(nil)
	return json.Number(integer.String()), nil
}

func roundedAtMost(value any, maximum int64) bool {
	switch value := value.(type) {
	case int64:
		return value <= maximum
	case json.Number:
		integer, ok := new(big.Int).SetString(value.String(), 10)
		return ok && integer.Cmp(big.NewInt(maximum)) <= 0
	default:
		return false
	}
}
