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
	case "poll_parse_proxy_list_worker":
		return pollParseProxyListWorker(request)
	case "poll_parse_legacy_dict_worker":
		return pollParseLegacyDictWorker(request)
	case "poll_parse_rigforge":
		return pollParseRigforge(request)
	case "poll_normalize_proxy_workers":
		return pollNormalizeProxyWorkers(request)
	case "poll_parse_proxy_summary":
		return pollParseProxySummary(request)
	case "poll_merge_proxy_summary":
		return pollMergeProxySummary(request)
	case "poll_merge_direct_stats":
		return pollMergeDirectStats(request)
	case "poll_merge_rigforge_stats":
		return pollMergeRigforgeStats(request)
	case "poll_preserve_reports":
		return pollPreserveReports(request)
	case "poll_aggregate_hashrate":
		return pollAggregateHashrate(request)
	case "poll_aggregate_window_hashrates":
		return pollAggregateWindowHashrates(request)
	case "poll_summary_deltas":
		return pollSummaryDeltas(request)
	case "poll_shares_to_record":
		return pollSharesToRecord(request)
	case "poll_lifecycle":
		return pollLifecycle(request)
	case "poll_probe_plan":
		return pollProbePlan(request)
	case "poll_probe_complete":
		return pollProbeComplete(request)
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
		var pollErr *PollError
		if request.Envelope && errors.As(err, &pollErr) {
			result = map[string]any{
				"ok":    false,
				"error": map[string]any{"kind": pollErr.Kind, "message": pollErr.Message},
			}
			if request.NonfiniteMarker != "" {
				result = packDetailValue(result, request.NonfiniteMarker)
			}
			return json.NewEncoder(output).Encode(result)
		}
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
