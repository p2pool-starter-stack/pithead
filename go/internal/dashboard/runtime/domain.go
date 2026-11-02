package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"net/url"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/domain"
	dashboardweb "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/web"
)

func buildDomainInputs(ctx context.Context, client *http.Client, target *url.URL, operation, query string, raw json.RawMessage) (json.RawMessage, error) {
	if operation != "state" && operation != "metrics" {
		return raw, nil
	}
	var fields map[string]json.RawMessage
	if json.Unmarshal(raw, &fields) != nil || fields["domain"] == nil {
		return raw, nil
	}
	var input domain.Input
	decoder := json.NewDecoder(bytes.NewReader(fields["domain"]))
	decoder.UseNumber()
	if decoder.Decode(&input) != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	metrics, err := domain.Build(input)
	if err != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	if operation == "state" {
		sections, err := infrastructureSections(input.LatestData, metrics)
		if err != nil {
			return nil, dashboardweb.ErrInputsUnavailable
		}
		if raw := fields["earnings"]; raw != nil {
			if string(raw) != "true" {
				return nil, dashboardweb.ErrInputsUnavailable
			}
			sections["build_earnings"], err = earningsSection(input.LatestData, metrics, fields["snapshot"])
			if err != nil {
				return nil, dashboardweb.ErrInputsUnavailable
			}
		}
		if raw := fields["forecast"]; raw != nil {
			if string(raw) != "true" {
				return nil, dashboardweb.ErrInputsUnavailable
			}
			sections["xvb_forecast"], err = forecastSection(metrics, sections["build_earnings"], fields["snapshot"])
			if err != nil {
				return nil, dashboardweb.ErrInputsUnavailable
			}
		}
		payloadFields := map[string]any{
			"latest_data": input.LatestData, "metrics": metrics,
			"sections": sections, "snapshot": fields["snapshot"],
		}
		if fields["earnings"] != nil {
			payloadFields["earnings"] = true
		}
		if fields["forecast"] != nil {
			payloadFields["forecast"] = true
		}
		compact := input.Averages != nil && fields["chart"] != nil
		if compact {
			payloadFields["compact_chart"] = true
		} else {
			payloadFields["history"] = input.History
		}
		payload, err := json.Marshal(payloadFields)
		if err != nil || len(payload) > 64<<20 {
			return nil, dashboardweb.ErrInputsUnavailable
		}
		result, err := requestInputs(ctx, client, target, operation, query, payload)
		if err != nil || !compact {
			return result, err
		}
		return attachPreparedChart(result, fields["chart"])
	}
	var shares []map[string]any
	decoder = json.NewDecoder(bytes.NewReader(fields["share_stats"]))
	decoder.UseNumber()
	if decoder.Decode(&shares) != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	rejects, err := domain.ShareRejectPct(shares, 3600, input.Now)
	if err != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	fields["Metrics"], err = json.Marshal(metrics)
	if err != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	fields["RejectPct1H"], err = json.Marshal(rejects)
	if err != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	delete(fields, "domain")
	delete(fields, "share_stats")
	return json.Marshal(fields)
}

func attachPreparedChart(raw, prepared json.RawMessage) (json.RawMessage, error) {
	var result map[string]json.RawMessage
	var chart map[string]json.RawMessage
	var compact struct {
		History  json.RawMessage `json:"history"`
		Shares   json.RawMessage `json:"shares"`
		Duration json.RawMessage `json:"duration"`
	}
	if json.Unmarshal(raw, &result) != nil || json.Unmarshal(result["chart"], &chart) != nil || json.Unmarshal(prepared, &compact) != nil || compact.History == nil || compact.Shares == nil || compact.Duration == nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	chart["history"] = compact.History
	chart["shares"] = compact.Shares
	chart["prepared_duration"] = compact.Duration
	var err error
	result["chart"], err = json.Marshal(chart)
	if err != nil {
		return nil, dashboardweb.ErrInputsUnavailable
	}
	return json.Marshal(result)
}
