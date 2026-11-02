package overview

func xvbCurrentTierKey(metrics map[string]any, tiers []xvbTier) (any, error) {
	oneHour, err := number(member(metrics, "xvb_1h", 0))
	if err != nil {
		return nil, err
	}
	twentyFour, err := number(member(metrics, "xvb_24h", 0))
	if err != nil {
		return nil, err
	}
	hashrate := min(oneHour, twentyFour)
	var key any
	best := 0.0
	for _, tier := range tiers {
		if tier.threshold > 0 && hashrate >= tier.threshold && tier.threshold > best {
			key, best = tier.key, tier.threshold
		}
	}
	return key, nil
}

func xvbForecastTierKey(metrics map[string]any, tiers []xvbTier) (any, error) {
	key, err := xvbCurrentTierKey(metrics, tiers)
	if err != nil || key != nil {
		return key, err
	}
	target, err := number(member(metrics, "target_threshold", 0))
	if err != nil {
		return nil, err
	}
	if target > 0 {
		for _, tier := range tiers {
			if tier.threshold == target {
				return tier.key, nil
			}
		}
	}
	return nil, nil
}

func xvbCurrentTierRewardDay(metrics map[string]any, tiers []xvbTier, state map[string]any, settings xvbSettings, now float64) (any, error) {
	if !truthy(member(metrics, "xvb_enabled", false)) {
		return nil, nil
	}
	keyValue, err := xvbCurrentTierKey(metrics, tiers)
	if err != nil || keyValue == nil {
		return nil, err
	}
	key := keyValue.(string)
	estimates, err := nestedObject(state, "estimates")
	if err != nil {
		return nil, err
	}
	stale, err := xvbStale(state, settings, now)
	if err != nil {
		return nil, err
	}
	if stale {
		return nil, nil
	}
	rewardValue, ok := estimates[key]
	if !ok || !truthy(rewardValue) {
		return nil, nil
	}
	reward, err := number(rewardValue)
	if err != nil || reward <= 0 {
		return nil, err
	}
	return reward / 365, nil
}

func xvbExpectedWinsDay(state map[string]any, tierKey any, tiers []xvbTier, settings xvbSettings, now float64) (any, error) {
	key, ok := tierKey.(string)
	stale, err := xvbStale(state, settings, now)
	if err != nil {
		return nil, err
	}
	if !ok || key == "" || stale {
		return nil, nil
	}
	stats, err := nestedObject(state, "stats")
	if err != nil {
		return nil, err
	}
	types, err := nestedObject(stats, "types")
	if err != nil {
		return nil, err
	}
	spanValue := member(stats, "span_days", 0)
	if !truthy(spanValue) {
		spanValue = 0
	}
	span, err := number(spanValue)
	if err != nil {
		return nil, err
	}
	if len(types) == 0 || span <= 0 {
		return nil, nil
	}
	held := 0.0
	for _, tier := range tiers {
		if tier.key == key {
			held = tier.threshold
			break
		}
	}
	total := newPythonSum()
	for _, tier := range tiers {
		if tier.threshold <= 0 || tier.threshold > held {
			continue
		}
		aggValue, ok := types[tier.key]
		if !ok || !truthy(aggValue) {
			continue
		}
		agg, err := object(aggValue)
		if err != nil {
			return nil, err
		}
		players := member(agg, "players_avg", 0)
		rounds := member(agg, "rounds", 0)
		playersNumber, err := number(players)
		if err != nil {
			return nil, err
		}
		roundsNumber, err := number(rounds)
		if err != nil {
			return nil, err
		}
		if playersNumber <= 0 || roundsNumber <= 0 {
			continue
		}
		perDay, err := pythonDivide(rounds, spanValue)
		if err != nil {
			return nil, err
		}
		odds, err := pythonDivide(perDay, players)
		if err != nil {
			return nil, err
		}
		if err := total.add(odds); err != nil {
			return nil, err
		}
	}
	result, err := total.divide(1)
	if err != nil || result <= 0 {
		return nil, err
	}
	return result, nil
}

func xvbRealization(payouts, wins []any, xvbDay, expected, p2pool *float64, settings xvbSettings, now float64) (any, error) {
	if len(payouts) == 0 || len(wins) == 0 || xvbDay == nil || expected == nil || *xvbDay == 0 || *expected == 0 {
		return nil, nil
	}
	lo := now - settings.realizationWindow
	stamps := make([]float64, 0, len(wins))
	for _, winValue := range wins {
		win, err := object(winValue)
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
		if stamp >= lo && stamp <= now-settings.settle {
			stamps = append(stamps, stamp)
		}
	}
	if len(stamps) < settings.minWins {
		return nil, nil
	}
	facePerWin := *xvbDay / *expected
	if facePerWin <= 0 {
		return nil, nil
	}
	realized := newPythonSum()
	for _, payoutValue := range payouts {
		payout, err := object(payoutValue)
		if err != nil {
			return nil, err
		}
		stampValue := member(payout, "ts", 0)
		if !truthy(stampValue) {
			stampValue = 0
		}
		stamp, err := number(stampValue)
		if err != nil {
			return nil, err
		}
		matched := false
		for _, winStamp := range stamps {
			if stamp-winStamp >= 0 && stamp-winStamp <= settings.payoutWindow {
				matched = true
				break
			}
		}
		if matched {
			amount := member(payout, "amount_atomic", 0)
			if !truthy(amount) {
				amount = 0
			}
			if err := realized.add(amount); err != nil {
				return nil, err
			}
		}
	}
	realizedXMR, err := realized.divide(1_000_000_000_000)
	if err != nil {
		return nil, err
	}
	if p2pool != nil && *p2pool > 0 {
		realizedXMR -= *p2pool * (settings.payoutWindow / 86400) * float64(len(stamps))
	}
	fraction := (realizedXMR / float64(len(stamps))) / facePerWin
	fraction = max(0, min(1, fraction))
	return []any{fraction, len(stamps)}, nil
}

func xvbTemperedDay(xvbDay *float64, realization *xvbMeasurement, settings xvbSettings) any {
	if xvbDay == nil {
		return nil
	}
	if *xvbDay == 0 {
		return float64(0)
	}
	fraction := (settings.priorLow + settings.priorHigh) / 2
	if realization != nil {
		fraction = realization.fraction
	}
	return *xvbDay * fraction
}
