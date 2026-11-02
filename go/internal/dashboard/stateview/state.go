package stateview

import (
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

type Request struct {
	Operation string `json:"operation"`
	Input     Input  `json:"input"`
}

type Input struct {
	SlotCount  *int            `json:"slot_count"`
	Syncing    *bool           `json:"syncing"`
	TariNeeded *bool           `json:"tari_required"`
	MoneroOnly *bool           `json:"monero_only"`
	Slots      map[string]int  `json:"slots"`
	Stratum    []StratumSlot   `json:"stratum"`
	Window     json.RawMessage `json:"window"`
}

type StratumSlot struct {
	Key   string
	Index int
}

type Ref struct {
	Ref int `json:"ref"`
}

type Pair [2]any

type Response struct {
	OK    bool   `json:"ok"`
	Value []Pair `json:"value"`
}

var fields = [][2]string{
	{"syncing", "metrics.global_syncing"},
	{"host_ip", "host_ip"},
	{"host_addr", "host_addr"},
	{"dashboard_onion", "dashboard_onion"},
	{"version", "version"},
	{"update", "visible_update"},
	{"control_enabled", "control_enabled"},
	{"os_update", "os_update"},
	{"last_update", "last_update"},
	{"range", "range_arg"},
	{"avg_window", "avg_window"},
	{"avg_windows", "avg_windows"},
	{"badges", "badges"},
	{"db_healthy", "db_healthy"},
	{"hashrate", "build_hashrate"},
	{"system", "build_system"},
	{"host_resources", "build_host_resources"},
	{"sync", "build_sync"},
	{"sync_status", "sync_status"},
	{"stratum", "pool.stratum"},
	{"pool", "pool.pool"},
	{"network", "pool.network"},
	{"monero", "pool.monero"},
	{"shares_window", "pool.shares_window"},
	{"cadence", "build_cadence"},
	{"raffle_eligible", "build_raffle_eligibility"},
	{"raffle_wins", "build_raffle_log"},
	{"proxy_workers", "metrics.workers_online"},
	{"earnings", "build_earnings"},
	{"earnings_summary", "build_earnings_vs_actual"},
	{"xvb_calc", "build_xvb_calc"},
	{"xvb_standby", "xvb_standby"},
	{"tari", "build_tari"},
	{"workers", "build_workers"},
	{"energy", "build_energy"},
	{"proxy_summary", "build_proxy_summary"},
	{"share_stats", "build_share_stats"},
	{"reject_pct_24h", "_window_reject_pct"},
	{"blocks", "build_blocks"},
	{"payouts", "build_payouts"},
	{"disk_growth", "build_disk_growth"},
	{"xvb_history", "build_xvb_history"},
	{"egress", "egress"},
	{"topology", "topology"},
	{"chart", "build_chart"},
}

func (slot *StratumSlot) UnmarshalJSON(data []byte) error {
	var values []json.RawMessage
	if err := json.Unmarshal(data, &values); err != nil {
		return err
	}
	if len(values) != 2 {
		return errors.New("stratum slot must have two values")
	}
	if err := json.Unmarshal(values[0], &slot.Key); err != nil {
		return errors.New("stratum key must be a string")
	}
	if err := json.Unmarshal(values[1], &slot.Index); err != nil {
		return errors.New("stratum index must be an integer")
	}
	return nil
}

func (slot StratumSlot) MarshalJSON() ([]byte, error) {
	return json.Marshal([2]any{slot.Key, slot.Index})
}

func Build(request Request) ([]Pair, error) {
	if request.Operation != "assemble" {
		return nil, errors.New("unsupported state operation")
	}
	input := request.Input
	if input.SlotCount == nil || input.Syncing == nil || input.TariNeeded == nil || input.MoneroOnly == nil || input.Slots == nil || input.Stratum == nil || input.Window == nil {
		return nil, errors.New("incomplete state input")
	}
	slotCount := *input.SlotCount
	if slotCount < 1 {
		return nil, errors.New("invalid slot count")
	}
	for key, index := range input.Slots {
		if key == "" || index < 0 || index >= slotCount {
			return nil, fmt.Errorf("invalid slot %q", key)
		}
	}
	refs := make(map[string]Ref, len(fields))
	for _, field := range fields {
		index, ok := input.Slots[field[1]]
		if !ok {
			return nil, fmt.Errorf("invalid slot %q", field[1])
		}
		refs[field[1]] = Ref{Ref: index}
	}

	window, err := buildWindow(input.Window, slotCount)
	if err != nil {
		return nil, err
	}
	stratum, err := buildStratum(input.Stratum, slotCount)
	if err != nil {
		return nil, err
	}

	pairs := make([]Pair, 0, len(fields)+len(stratum)+3)
	pairs = append(pairs,
		Pair{"syncing", refs["metrics.global_syncing"]},
		Pair{"tari_gates_sync", *input.TariNeeded && !*input.MoneroOnly},
		Pair{"page_title", pageTitle(*input.Syncing)},
		Pair{"host_ip", refs["host_ip"]},
		Pair{"host_addr", refs["host_addr"]},
		Pair{"dashboard_onion", refs["dashboard_onion"]},
	)
	pairs = append(pairs, stratum...)
	for _, field := range fields[4:10] {
		pairs = append(pairs, Pair{field[0], refs[field[1]]})
	}
	pairs = append(pairs, Pair{"window", window})
	for _, field := range fields[10:] {
		pairs = append(pairs, Pair{field[0], refs[field[1]]})
	}
	return pairs, nil
}

func Run(input io.Reader, output io.Writer) error {
	decoder := json.NewDecoder(input)
	decoder.DisallowUnknownFields()
	var request Request
	if err := decoder.Decode(&request); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple state inputs")
		}
		return err
	}
	value, err := Build(request)
	if err != nil {
		return err
	}
	return json.NewEncoder(output).Encode(Response{OK: true, Value: value})
}

func buildWindow(raw json.RawMessage, slotCount int) (any, error) {
	if len(raw) == 0 || string(raw) == "null" {
		return nil, nil
	}
	var indices []int
	if err := json.Unmarshal(raw, &indices); err != nil || len(indices) != 2 {
		return nil, errors.New("invalid state window")
	}
	if indices[0] < 0 || indices[0] >= slotCount || indices[1] < 0 || indices[1] >= slotCount {
		return nil, errors.New("invalid state window index")
	}
	return map[string]Ref{"from": {Ref: indices[0]}, "to": {Ref: indices[1]}}, nil
}

func buildStratum(slots []StratumSlot, slotCount int) ([]Pair, error) {
	seen := make(map[string]struct{}, len(slots))
	pairs := make([]Pair, 0, len(slots))
	for _, slot := range slots {
		if slot.Key == "" || slot.Index < 0 || slot.Index >= slotCount {
			return nil, errors.New("invalid stratum slot")
		}
		if _, ok := seen[slot.Key]; ok {
			return nil, errors.New("duplicate stratum key")
		}
		seen[slot.Key] = struct{}{}
		pairs = append(pairs, Pair{slot.Key, Ref{Ref: slot.Index}})
	}
	return pairs, nil
}

func pageTitle(syncing bool) string {
	if syncing {
		return "Pithead Dashboard - Syncing"
	}
	return "Pithead Dashboard"
}
