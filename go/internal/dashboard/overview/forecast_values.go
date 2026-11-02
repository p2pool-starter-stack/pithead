package overview

import "errors"

func xvbInputs(metricsValue, tiersValue any) (map[string]any, []xvbTier, error) {
	metrics, err := object(metricsValue)
	if err != nil {
		return nil, nil, err
	}
	tiers, err := parseXVBTiers(tiersValue)
	return metrics, tiers, err
}

func parseXVBTiers(value any) ([]xvbTier, error) {
	rows, err := array(value)
	if err != nil {
		return nil, err
	}
	tiers := make([]xvbTier, 0, len(rows))
	for _, rowValue := range rows {
		row, err := object(rowValue)
		if err != nil {
			return nil, err
		}
		name, ok := member(row, "name", nil).(string)
		if !ok || name == "" {
			return nil, errors.New("invalid tier name")
		}
		threshold, err := number(member(row, "threshold", nil))
		if err != nil {
			return nil, err
		}
		display, err := required(row, "display")
		if err != nil {
			return nil, err
		}
		if _, ok := display.(string); !ok {
			return nil, errors.New("invalid tier display")
		}
		tiers = append(tiers, xvbTier{name, threshold, display})
	}
	return tiers, nil
}

func parseXVBSettings(value any) (xvbSettings, error) {
	settings, err := object(value)
	if err != nil {
		return xvbSettings{}, err
	}
	field := func(key string) (any, error) { return required(settings, key) }
	numberField := func(key string) (float64, error) {
		value, err := field(key)
		if err != nil {
			return 0, err
		}
		return number(value)
	}
	stale, err := numberField("stale_after_s")
	if err != nil {
		return xvbSettings{}, err
	}
	priorValue, err := field("prior")
	if err != nil {
		return xvbSettings{}, err
	}
	prior, err := array(priorValue)
	if err != nil || len(prior) != 2 {
		return xvbSettings{}, errors.New("invalid realization prior")
	}
	priorLow, err := number(prior[0])
	if err != nil {
		return xvbSettings{}, err
	}
	priorHigh, err := number(prior[1])
	if err != nil {
		return xvbSettings{}, err
	}
	publishedValue, err := field("published_rewards")
	if err != nil {
		return xvbSettings{}, err
	}
	published, err := object(publishedValue)
	if err != nil {
		return xvbSettings{}, err
	}
	payoutWindow, err := numberField("payout_window_s")
	if err != nil {
		return xvbSettings{}, err
	}
	settle, err := numberField("settle_s")
	if err != nil {
		return xvbSettings{}, err
	}
	minWinsValue, err := numberField("min_wins")
	if err != nil {
		return xvbSettings{}, err
	}
	realizationWindow, err := numberField("realization_window_s")
	if err != nil {
		return xvbSettings{}, err
	}
	maxFraction, err := field("max_fraction")
	if err != nil {
		return xvbSettings{}, err
	}
	if _, err := number(maxFraction); err != nil {
		return xvbSettings{}, err
	}
	publishedDate, err := field("published_date")
	if err != nil {
		return xvbSettings{}, err
	}
	tierNote, err := field("tier_note")
	if err != nil {
		return xvbSettings{}, err
	}
	sidechainNote, err := field("sidechain_note")
	if err != nil {
		return xvbSettings{}, err
	}
	for _, value := range []any{publishedDate, tierNote, sidechainNote} {
		if _, ok := value.(string); !ok {
			return xvbSettings{}, errors.New("invalid display setting")
		}
	}
	return xvbSettings{
		staleAfter: stale, maxFraction: maxFraction, priorLow: priorLow,
		priorHigh: priorHigh, publishedRewards: published, publishedDate: publishedDate,
		tierNote: tierNote, sidechainNote: sidechainNote,
		payoutWindow: payoutWindow, settle: settle, minWins: int(minWinsValue), realizationWindow: realizationWindow,
	}, nil
}

func xvbStale(state map[string]any, settings xvbSettings, now float64) (bool, error) {
	lastValue := member(state, "last_update", 0)
	if !truthy(lastValue) {
		return false, nil
	}
	last, err := number(lastValue)
	if err != nil {
		return false, err
	}
	return last > 0 && now-last > settings.staleAfter, nil
}

func nestedObject(value map[string]any, key string) (map[string]any, error) {
	memberValue := member(value, key, nil)
	if !truthy(memberValue) {
		return map[string]any{}, nil
	}
	return object(memberValue)
}

func nullableObject(value any) (map[string]any, error) {
	if value == nil {
		return map[string]any{}, nil
	}
	return object(value)
}

func nullableArrayValue(value any) ([]any, error) {
	if value == nil {
		return nil, nil
	}
	return array(value)
}

func optionalNumber(value any) (*float64, error) {
	if value == nil {
		return nil, nil
	}
	n, err := number(value)
	if err != nil {
		return nil, err
	}
	return &n, nil
}

func nullableString(value any) (any, error) {
	if value == nil {
		return nil, nil
	}
	text, ok := value.(string)
	if !ok {
		return nil, errors.New("expected string")
	}
	return text, nil
}

func parseXVBMeasurement(value any) (*xvbMeasurement, error) {
	if value == nil {
		return nil, nil
	}
	values, err := array(value)
	if err != nil || len(values) != 2 {
		return nil, errors.New("invalid realization")
	}
	fraction, err := number(values[0])
	if err != nil {
		return nil, err
	}
	return &xvbMeasurement{fraction: fraction, wins: values[1]}, nil
}

func measurementValue(value *xvbMeasurement) any {
	if value == nil {
		return nil
	}
	return []any{value.fraction, value.wins}
}
