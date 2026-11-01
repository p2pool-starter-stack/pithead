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
		payload, err := json.Marshal(map[string]any{
			"latest_data": input.LatestData, "history": input.History, "metrics": metrics, "sections": sections,
		})
		if err != nil || len(payload) > 64<<20 {
			return nil, dashboardweb.ErrInputsUnavailable
		}
		return requestInputs(ctx, client, target, operation, query, payload)
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
