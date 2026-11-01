package fleet

import (
	"encoding/json"
	"errors"
)

const energyDisclaimer = "Power draw is measured (RAPL, 15s sample) or your per-worker estimate; a worker reporting neither is excluded and the fleet total is marked incomplete. kWh and cost extrapolate the current draw at a constant rate — a naive projection, not a metered bill. Gross revenue is P2Pool XMR earnings valued at the XMR price in use (your configured price, or the live CoinGecko-over-Tor feed when dashboard.energy.price_feed is on), plus Tari merge-mining earnings when merge-mining and a Tari price are available, plus a fresh current donor-tier XvB estimate valued at the same XMR price when usable. XvB is tempered by your wallet's measured delivery when enough wins exist, else the measured delivery band's midpoint; missing or stale estimates are excluded. Net subtracts power cost and needs both an XMR price and an electricity price. Missing prices leave those figures unavailable. Partial power coverage understates cost and can overstate net. Mining payouts vary and the XvB raffle draw is random among qualifiers. Estimates, not guarantees."

func buildEnergy(raw []json.RawMessage, now float64) (any, error) {
	values, err := arguments(raw, 4)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	var prices map[string]any
	if truthy(values[1]) {
		prices, err = object(values[1])
		if err != nil {
			return nil, err
		}
	}
	config, err := object(values[2])
	if err != nil {
		return nil, err
	}
	endpoints, err := array(values[3])
	if err != nil {
		return nil, err
	}
	priceFeed, err := required(config, "price_feed")
	if err != nil {
		return nil, err
	}
	staticXMR, err := required(config, "xmr_price")
	if err != nil {
		return nil, err
	}
	staticTari, err := required(config, "tari_price")
	if err != nil {
		return nil, err
	}
	cost, err := required(config, "cost_per_kwh")
	if err != nil {
		return nil, err
	}
	currency, err := required(config, "currency")
	if err != nil {
		return nil, err
	}
	feed := truthy(priceFeed)
	live := feed && len(prices) != 0
	var age any
	if live {
		fetched, ok := numeric(member(prices, "fetched_at", nil))
		if !ok {
			return nil, errors.New("invalid live price timestamp")
		}
		age = pythonRound(now-fetched, 0)
	}
	xmrPrice := staticXMR
	tariPrice := staticTari
	if live {
		xmrPrice, err = required(prices, "xmr")
		if err != nil {
			return nil, err
		}
		tariPrice, err = required(prices, "tari")
		if err != nil {
			return nil, err
		}
	}
	perWorker := make([]any, 0, len(workers))
	totalWatts, poweredHashrate := 0.0, 0.0
	incomplete := false
	for _, value := range workers {
		worker, err := object(value)
		if err != nil {
			return nil, err
		}
		name, ok := member(worker, "name", "").(string)
		if !ok {
			return nil, errors.New("invalid worker name")
		}
		var rf map[string]any
		if truthy(member(worker, "rigforge", nil)) {
			rf, err = object(worker["rigforge"])
			if err != nil {
				return nil, err
			}
			if age, fresh := feedAge(member(rf, "generated_at", nil), now); !fresh || age > 60 {
				rf = nil
			}
		}
		power := map[string]any{}
		if rf != nil {
			power, err = optionalObject(rf, "power")
			if err != nil {
				return nil, err
			}
		}
		wattsRaw, watts, haveWatts := numericRaw(member(power, "watts", nil))
		estimated := false
		if !haveWatts || watts <= 0 {
			wattsRaw, watts, haveWatts, err = configuredWatts(name, endpoints)
			if err != nil {
				return nil, err
			}
			estimated = haveWatts
		}
		hashrateRaw, hashrate, haveHashrate := numericRaw(member(worker, "h60", nil))
		if !haveHashrate {
			hashrate = 0
		}
		hashrateOutput := any(float64(0))
		if haveHashrate && hashrate != 0 {
			hashrateOutput = hashrateRaw
		}
		if !haveWatts {
			incomplete = true
			perWorker = append(perWorker, map[string]any{"name": name, "watts": nil, "estimated": false, "hs": hashrateOutput, "hs_per_watt": nil})
			continue
		}
		roundedWatts, err := roundedOutput(wattsRaw, 1)
		if err != nil {
			return nil, err
		}
		totalWatts += watts
		poweredHashrate += hashrate
		perWorker = append(perWorker, map[string]any{
			"name": name, "watts": roundedWatts, "estimated": estimated,
			"hs": hashrateOutput, "hs_per_watt": pythonRound(hashrate/watts, 2),
		})
	}
	havePower := totalWatts > 0
	var total, efficiency any
	if havePower {
		total = pythonRound(totalWatts, 1)
		efficiency = pythonRound(poweredHashrate/totalWatts, 2)
	}
	return map[string]any{
		"available": havePower, "total_watts": total, "hs_per_watt": efficiency,
		"incomplete": incomplete, "cost_per_kwh": cost,
		"xmr_price": xmrPrice, "tari_price": tariPrice, "currency": currency,
		"price_source": map[string]any{"feed": feed, "live": live, "age_sec": age},
		"per_worker":   perWorker, "disclaimer": energyDisclaimer,
	}, nil
}

func configuredWatts(name string, endpoints []any) (any, float64, bool, error) {
	for _, value := range endpoints {
		endpoint, err := object(value)
		if err != nil {
			return nil, 0, false, err
		}
		endpointName, ok := member(endpoint, "name", nil).(string)
		if !ok {
			return nil, 0, false, errors.New("invalid worker endpoint")
		}
		if endpointName != name {
			continue
		}
		raw, watts, ok := numericRaw(member(endpoint, "watts", nil))
		return raw, watts, ok && watts > 0, nil
	}
	return nil, 0, false, nil
}

func numericRaw(value any) (any, float64, bool) {
	if integer, ok := integerNumber(value); ok {
		number, valid := numeric(value)
		return json.Number(integer.String()), number, valid
	}
	number, ok := numeric(value)
	if !ok {
		return nil, 0, false
	}
	return number, number, true
}

func roundedOutput(value any, places int) (any, error) {
	if integer, ok := integerNumber(value); ok {
		return json.Number(integer.String()), nil
	}
	number, ok := numeric(value)
	if !ok {
		return nil, errors.New("invalid numeric output")
	}
	return pythonRound(number, places), nil
}
