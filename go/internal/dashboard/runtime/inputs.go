package runtime

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/url"
	"sync"
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
	collect := func(ctx context.Context, operation string, query string) (json.RawMessage, error) {
		raw, err := requestInputs(ctx, client, target, operation, query, nil)
		if err != nil {
			return nil, err
		}
		return buildDomainInputs(ctx, client, target, operation, query, raw)
	}
	var lock sync.Mutex
	flights := make(map[string]*inputFlight)
	changed := make(chan struct{})
	return func(ctx context.Context, operation, query string) (json.RawMessage, error) {
		if operation != "state" {
			return collect(ctx, operation, query)
		}
		var flight *inputFlight
		for {
			if err := ctx.Err(); err != nil {
				return nil, err
			}
			lock.Lock()
			flight = flights[query]
			if flight != nil && flight.waiters > 0 || flight == nil && len(flights) < 4 {
				break
			}
			available := changed
			lock.Unlock()
			select {
			case <-ctx.Done():
				return nil, ctx.Err()
			case <-available:
			}
		}
		if flight == nil {
			shared, cancel := context.WithTimeout(context.WithoutCancel(ctx), 30*time.Second)
			flight = &inputFlight{done: make(chan struct{}), cancel: cancel}
			flights[query] = flight
			go func() {
				defer cancel()
				flight.value, flight.err = collect(shared, operation, query)
				lock.Lock()
				delete(flights, query)
				close(flight.done)
				close(changed)
				changed = make(chan struct{})
				lock.Unlock()
			}()
		}
		flight.waiters++
		lock.Unlock()
		defer func() {
			lock.Lock()
			flight.waiters--
			if flight.waiters == 0 {
				flight.cancel()
			}
			lock.Unlock()
		}()
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		case <-flight.done:
			return flight.value, flight.err
		}
	}
}

type inputFlight struct {
	done    chan struct{}
	value   json.RawMessage
	err     error
	cancel  context.CancelFunc
	waiters int
}

func requestInputs(ctx context.Context, client *http.Client, target *url.URL, operation, query string, payload []byte) (json.RawMessage, error) {
	endpoint := *target
	endpoint.Path = "/_go/" + operation
	endpoint.RawQuery = query
	method := http.MethodGet
	if payload != nil {
		method = http.MethodPost
	}
	request, err := http.NewRequestWithContext(ctx, method, endpoint.String(), bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	if payload != nil {
		request.Header.Set("Content-Type", "application/json")
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
