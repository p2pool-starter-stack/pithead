package overview

import (
	"encoding/json"
	"errors"
	"io"
	"math"
)

type Request struct {
	Operation       string            `json:"operation"`
	Args            []json.RawMessage `json:"args"`
	Now             float64           `json:"now"`
	Zone            string            `json:"zone"`
	NonfiniteMarker string            `json:"nonfinite_marker,omitempty"`
}

func Build(request Request) (any, error) {
	switch request.Operation {
	case "build_pool_network":
		return buildPoolNetwork(request)
	case "build_raffle_log":
		return buildRaffleLog(request)
	case "build_raffle_eligibility":
		return buildRaffleEligibility(request)
	case "_egress_badge":
		return buildEgressBadge(request)
	case "visible_update":
		return buildVisibleUpdate(request)
	case "xmr_per_hs_day":
		return buildXMRPerHSDay(request)
	case "xtm_per_hs_day":
		return buildXTMPerHSDay(request)
	case "tari_seconds_to_block_per_hs":
		return buildTariSecondsToBlockPerHS(request)
	case "previous_local_day":
		return buildPreviousLocalDay(request)
	case "confirmed_payouts_summary":
		return buildConfirmedPayoutsSummary(request)
	case "build_earnings":
		return buildEarnings(request)
	case "build_earnings_vs_actual":
		return buildEarningsVsActual(request)
	case "xvb_current_tier_key":
		return buildXVBCurrentTierKey(request)
	case "xvb_forecast_tier_key":
		return buildXVBForecastTierKey(request)
	case "xvb_current_tier_reward_day":
		return buildXVBCurrentTierRewardDay(request)
	case "xvb_expected_wins_day":
		return buildXVBExpectedWinsDay(request)
	case "xvb_realization":
		return buildXVBRealization(request)
	case "xvb_tempered_day":
		return buildXVBTemperedDay(request)
	case "build_xvb_calc":
		return buildXVBCalc(request)
	case "xvb_state":
		return buildXVBState(request)
	default:
		return nil, errors.New("unsupported overview operation")
	}
}

func Run(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	decoder.UseNumber()
	var request Request
	if err := decoder.Decode(&request); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple overview inputs")
		}
		return err
	}
	result, err := Build(request)
	if err != nil {
		return err
	}
	if request.NonfiniteMarker != "" {
		result = packNonfinite(result, request.NonfiniteMarker)
	}
	return json.NewEncoder(output).Encode(result)
}

func packNonfinite(value any, marker string) any {
	switch value := value.(type) {
	case float64:
		label := ""
		switch {
		case math.IsNaN(value):
			label = "nan"
		case math.IsInf(value, 1):
			label = "inf"
		case math.IsInf(value, -1):
			label = "-inf"
		}
		if label != "" {
			return map[string]any{marker: label}
		}
	case []any:
		result := make([]any, len(value))
		for index, item := range value {
			result[index] = packNonfinite(item, marker)
		}
		return result
	case map[string]any:
		result := make(map[string]any, len(value))
		for key, item := range value {
			result[key] = packNonfinite(item, marker)
		}
		return result
	}
	return value
}
