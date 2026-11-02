package overview

import "sort"

func xvbCalc(metrics map[string]any, tiers []xvbTier, roundState, estimateState map[string]any, realization *xvbMeasurement, settings xvbSettings, now float64) (map[string]any, error) {
	roundStats, err := nestedObject(roundState, "stats")
	if err != nil {
		return nil, err
	}
	roundTypes, err := nestedObject(roundStats, "types")
	if err != nil {
		return nil, err
	}
	roundStale, err := xvbStale(roundState, settings, now)
	if err != nil {
		return nil, err
	}
	if roundStale {
		roundTypes = map[string]any{}
	}
	spanValue := member(roundStats, "span_days", 0)
	if !truthy(spanValue) {
		spanValue = 0
	}
	span, err := number(spanValue)
	if err != nil {
		return nil, err
	}
	estimates, err := nestedObject(estimateState, "estimates")
	if err != nil {
		return nil, err
	}
	estimatesStale, err := xvbStale(estimateState, settings, now)
	if err != nil {
		return nil, err
	}
	estimatesAvailable := len(estimates) > 0 && !estimatesStale
	enabled := truthy(member(metrics, "xvb_enabled", false))
	fallbackUsed := false
	rows := make([]map[string]any, 0, len(tiers))
	for _, tier := range tiers {
		if tier.threshold <= 0 {
			continue
		}
		var face, liveFace any
		if estimatesAvailable {
			if value, ok := estimates[tier.key]; ok {
				n, err := number(value)
				if err != nil {
					return nil, err
				}
				face, liveFace = n, n
			}
		} else if !enabled {
			if value, ok := settings.publishedRewards[tier.key]; ok {
				n, err := number(value)
				if err != nil {
					return nil, err
				}
				face = n
				fallbackUsed = true
			}
		}
		var realized, assumed, odds, players any
		if liveFace != nil && realization != nil {
			realized = liveFace.(float64) * realization.fraction
		}
		if face != nil && realization == nil {
			assumed = []any{face.(float64) * settings.priorLow, face.(float64) * settings.priorHigh}
		}
		if aggValue, ok := roundTypes[tier.key]; ok {
			agg, err := object(aggValue)
			if err != nil {
				return nil, err
			}
			players = member(agg, "players_avg", nil)
			playersNumber, err := optionalNumber(players)
			if err != nil {
				return nil, err
			}
			if span > 0 && playersNumber != nil && *playersNumber > 0 {
				perDay, err := pythonDivide(member(agg, "rounds", 0), spanValue)
				if err != nil {
					return nil, err
				}
				odds, err = pythonDivide(perDay, players)
				if err != nil {
					return nil, err
				}
			}
		}
		rows = append(rows, map[string]any{"name": tier.display, "threshold": tier.threshold, "expected_reward_year": face,
			"realized_reward_year": realized, "assumed_reward_year_range": assumed, "win_odds_day": odds, "players_avg": players})
	}
	sort.SliceStable(rows, func(i, j int) bool { return rows[i]["threshold"].(float64) < rows[j]["threshold"].(float64) })
	source := "none"
	var publishedDate any
	if estimatesAvailable {
		source = "live"
	} else if fallbackUsed {
		source, publishedDate = "published", settings.publishedDate
	}
	var realizationPct, realizationWins any
	if realization != nil {
		realizationPct, err = pythonRound(realization.fraction * 100)
		if err != nil {
			return nil, err
		}
		realizationWins = realization.wins
	}
	modeNote := settings.sidechainNote
	if member(metrics, "pool_type", nil) == "Main" {
		modeNote = nil
	}
	return map[string]any{
		"enabled": enabled, "tiers": rows, "estimates_available": estimatesAvailable, "estimates_stale": estimatesStale,
		"estimates_source": source, "estimates_published_date": publishedDate, "realization_pct": realizationPct,
		"realization_wins": realizationWins, "max_fraction": settings.maxFraction,
		"current_tier": member(metrics, "current_tier", nil), "target_tier": member(metrics, "target_tier", nil),
		"target_threshold": member(metrics, "target_threshold", nil), "sustainable": member(metrics, "target_sustainable", nil),
		"note": settings.tierNote, "mode_note": modeNote,
	}, nil
}
