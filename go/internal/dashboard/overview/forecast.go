package overview

type xvbTier struct {
	key       string
	threshold float64
	display   any
}

type xvbSettings struct {
	staleAfter        float64
	maxFraction       any
	priorLow          float64
	priorHigh         float64
	publishedRewards  map[string]any
	publishedDate     any
	tierNote          any
	sidechainNote     any
	payoutWindow      float64
	settle            float64
	minWins           int
	realizationWindow float64
}

type xvbMeasurement struct {
	fraction float64
	wins     any
}

func buildXVBCurrentTierKey(request Request) (any, error) {
	args, err := arguments(request.Args, 2)
	if err != nil {
		return nil, err
	}
	metrics, tiers, err := xvbInputs(args[0], args[1])
	if err != nil {
		return nil, err
	}
	return xvbCurrentTierKey(metrics, tiers)
}

func buildXVBForecastTierKey(request Request) (any, error) {
	args, err := arguments(request.Args, 2)
	if err != nil {
		return nil, err
	}
	metrics, tiers, err := xvbInputs(args[0], args[1])
	if err != nil {
		return nil, err
	}
	return xvbForecastTierKey(metrics, tiers)
}

func buildXVBCurrentTierRewardDay(request Request) (any, error) {
	args, err := arguments(request.Args, 4)
	if err != nil {
		return nil, err
	}
	metrics, tiers, err := xvbInputs(args[0], args[1])
	if err != nil {
		return nil, err
	}
	estimates, err := nullableObject(args[2])
	if err != nil {
		return nil, err
	}
	settings, err := parseXVBSettings(args[3])
	if err != nil {
		return nil, err
	}
	return xvbCurrentTierRewardDay(metrics, tiers, estimates, settings, request.Now)
}

func buildXVBExpectedWinsDay(request Request) (any, error) {
	args, err := arguments(request.Args, 4)
	if err != nil {
		return nil, err
	}
	roundState, err := nullableObject(args[0])
	if err != nil {
		return nil, err
	}
	tierKey, err := nullableString(args[1])
	if err != nil {
		return nil, err
	}
	tiers, err := parseXVBTiers(args[2])
	if err != nil {
		return nil, err
	}
	settings, err := parseXVBSettings(args[3])
	if err != nil {
		return nil, err
	}
	return xvbExpectedWinsDay(roundState, tierKey, tiers, settings, request.Now)
}

func buildXVBRealization(request Request) (any, error) {
	args, err := arguments(request.Args, 6)
	if err != nil {
		return nil, err
	}
	payouts, err := nullableArrayValue(args[0])
	if err != nil {
		return nil, err
	}
	wins, err := nullableArrayValue(args[1])
	if err != nil {
		return nil, err
	}
	xvbDay, err := optionalNumber(args[2])
	if err != nil {
		return nil, err
	}
	expected, err := optionalNumber(args[3])
	if err != nil {
		return nil, err
	}
	p2pool, err := optionalNumber(args[4])
	if err != nil {
		return nil, err
	}
	settings, err := parseXVBSettings(args[5])
	if err != nil {
		return nil, err
	}
	return xvbRealization(payouts, wins, xvbDay, expected, p2pool, settings, request.Now)
}

func buildXVBTemperedDay(request Request) (any, error) {
	args, err := arguments(request.Args, 3)
	if err != nil {
		return nil, err
	}
	xvbDay, err := optionalNumber(args[0])
	if err != nil {
		return nil, err
	}
	measurement, err := parseXVBMeasurement(args[1])
	if err != nil {
		return nil, err
	}
	settings, err := parseXVBSettings(args[2])
	if err != nil {
		return nil, err
	}
	return xvbTemperedDay(xvbDay, measurement, settings), nil
}

func buildXVBCalc(request Request) (any, error) {
	args, err := arguments(request.Args, 6)
	if err != nil {
		return nil, err
	}
	metrics, tiers, err := xvbInputs(args[0], args[1])
	if err != nil {
		return nil, err
	}
	roundState, err := nullableObject(args[2])
	if err != nil {
		return nil, err
	}
	estimateState, err := nullableObject(args[3])
	if err != nil {
		return nil, err
	}
	measurement, err := parseXVBMeasurement(args[4])
	if err != nil {
		return nil, err
	}
	settings, err := parseXVBSettings(args[5])
	if err != nil {
		return nil, err
	}
	return xvbCalc(metrics, tiers, roundState, estimateState, measurement, settings, request.Now)
}

func buildXVBState(request Request) (any, error) {
	args, err := arguments(request.Args, 8)
	if err != nil {
		return nil, err
	}
	metrics, tiers, err := xvbInputs(args[0], args[1])
	if err != nil {
		return nil, err
	}
	roundState, err := nullableObject(args[2])
	if err != nil {
		return nil, err
	}
	estimateState, err := nullableObject(args[3])
	if err != nil {
		return nil, err
	}
	payouts, err := nullableArrayValue(args[4])
	if err != nil {
		return nil, err
	}
	wins, err := nullableArrayValue(args[5])
	if err != nil {
		return nil, err
	}
	coeffDay, err := optionalNumber(args[6])
	if err != nil {
		return nil, err
	}
	settings, err := parseXVBSettings(args[7])
	if err != nil {
		return nil, err
	}
	currentKey, err := xvbCurrentTierKey(metrics, tiers)
	if err != nil {
		return nil, err
	}
	forecastKey, err := xvbForecastTierKey(metrics, tiers)
	if err != nil {
		return nil, err
	}
	xvbDay, err := xvbCurrentTierRewardDay(metrics, tiers, estimateState, settings, request.Now)
	if err != nil {
		return nil, err
	}
	xvbDayNumber, err := optionalNumber(xvbDay)
	if err != nil {
		return nil, err
	}
	var expected any
	var realization *xvbMeasurement
	if truthy(member(metrics, "xvb_enabled", false)) {
		expected, err = xvbExpectedWinsDay(roundState, forecastKey, tiers, settings, request.Now)
		if err != nil {
			return nil, err
		}
		expectedNumber, err := optionalNumber(expected)
		if err != nil {
			return nil, err
		}
		p2pool30d, err := number(member(metrics, "p2pool_30d", 0))
		if err != nil {
			return nil, err
		}
		var p2poolDay *float64
		if coeffDay != nil {
			value := *coeffDay * p2pool30d
			p2poolDay = &value
		}
		realizationValue, err := xvbRealization(payouts, wins, xvbDayNumber, expectedNumber, p2poolDay, settings, request.Now)
		if err != nil {
			return nil, err
		}
		realization, err = parseXVBMeasurement(realizationValue)
		if err != nil {
			return nil, err
		}
	}
	calc, err := xvbCalc(metrics, tiers, roundState, estimateState, realization, settings, request.Now)
	if err != nil {
		return nil, err
	}
	return map[string]any{
		"current_key": currentKey, "forecast_key": forecastKey, "xvb_day": xvbDay,
		"expected_wins_day": expected, "realization": measurementValue(realization),
		"tempered_day": xvbTemperedDay(xvbDayNumber, realization, settings), "xvb_calc": calc,
	}, nil
}
