package fleet

import (
	"encoding/json"
	"errors"
	"io"
)

type Request struct {
	Operation       string            `json:"operation"`
	Args            []json.RawMessage `json:"args"`
	Now             float64           `json:"now"`
	Zone            string            `json:"zone"`
	Envelope        bool              `json:"envelope,omitempty"`
	NonfiniteMarker string            `json:"nonfinite_marker,omitempty"`
}

func Build(request Request) (any, error) {
	switch request.Operation {
	case "build_workers":
		return buildWorkers(request.Args, request.Now)
	case "build_energy":
		return buildEnergy(request.Args, request.Now)
	case "rigforge_display":
		return buildRigforgeDisplay(request.Args, request.Now)
	case "rigforge_update_for":
		return buildRigforgeUpdate(request.Args, request.Now)
	case "_reject_flag":
		return buildRejectFlag(request.Args)
	case "_ip_to_sort_int":
		return buildIPSort(request.Args)
	case "_num":
		return buildNum(request.Args)
	case "_fmt":
		return buildFmt(request.Args)
	case "config_drift":
		return buildConfigDrift(request)
	case "_has_unsettled_apply":
		return buildHasUnsettledApply(request)
	case "config_origin":
		return buildConfigOrigin(request)
	case "build_worker_hashrate_history":
		return buildWorkerHashrateHistory(request)
	case "build_worker_detail":
		return buildWorkerDetail(request)
	default:
		return nil, errors.New("unsupported fleet operation")
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
			return errors.New("multiple fleet inputs")
		}
		return err
	}
	result, err := Build(request)
	if err != nil {
		return err
	}
	if request.Envelope {
		result = map[string]any{"ok": true, "value": result}
	}
	if request.NonfiniteMarker != "" {
		result = packDetailValue(result, request.NonfiniteMarker)
	}
	return json.NewEncoder(output).Encode(result)
}
