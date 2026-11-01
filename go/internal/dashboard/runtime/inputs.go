package runtime

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"time"

	dashboardweb "github.com/p2pool-starter-stack/pithead/go/internal/dashboard/web"
)

func inputProvider(target *url.URL) dashboardweb.InputProvider {
	client := &http.Client{
		Timeout: 30 * time.Second,
		Transport: &http.Transport{
			Proxy: nil,
		},
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse },
	}
	return func(ctx context.Context, operation string, query string) (json.RawMessage, error) {
		endpoint := *target
		endpoint.Path = "/_go/" + operation
		endpoint.RawQuery = query
		request, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint.String(), nil)
		if err != nil {
			return nil, err
		}
		response, err := client.Do(request)
		if err != nil {
			return nil, errors.New("could not collect dashboard inputs")
		}
		defer response.Body.Close()
		if response.StatusCode != http.StatusOK && response.StatusCode != http.StatusInternalServerError {
			return nil, dashboardweb.ErrInputsUnavailable
		}
		if response.StatusCode != http.StatusOK {
			return nil, errors.New("dashboard input collection failed")
		}
		const limit = 64 << 20
		body, err := io.ReadAll(io.LimitReader(response.Body, limit+1))
		if err != nil || len(body) > limit {
			return nil, dashboardweb.ErrInputsUnavailable
		}
		var envelope struct {
			OK    bool            `json:"ok"`
			Input json.RawMessage `json:"input"`
		}
		if json.Unmarshal(body, &envelope) != nil || len(envelope.Input) == 0 {
			return nil, dashboardweb.ErrInputsUnavailable
		}
		if !envelope.OK {
			return nil, errors.New("dashboard input collection failed")
		}
		return envelope.Input, nil
	}
}
