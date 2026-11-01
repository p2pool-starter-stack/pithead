package web

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"strings"

	"github.com/p2pool-starter-stack/pithead/go/internal/dashboard/api"
)

type InputProvider func(context.Context, string, string) (json.RawMessage, error)

var ErrInputsUnavailable = errors.New("Go dashboard inputs unavailable")

func isDataRoute(path string) bool {
	switch path {
	case "/api/state", "/api/miner-connection", "/api/xvb-standby", "/metrics":
		return true
	}
	return false
}

func (h *handler) serveData(w http.ResponseWriter, r *http.Request) {
	operation := strings.TrimPrefix(r.URL.Path, "/api/")
	if r.URL.Path == "/metrics" {
		operation = "metrics"
	}
	raw, err := h.options.Inputs(r.Context(), operation, r.URL.RawQuery)
	if errors.Is(err, ErrInputsUnavailable) {
		h.dataFallback(w, r)
		return
	}
	if err != nil {
		if operation == "miner-connection" {
			h.dataFallback(w, r)
			return
		}
		writeDataError(w, r)
		return
	}
	var result any
	switch operation {
	case "state":
		result, err = buildState(raw)
	case "miner-connection":
		var input api.MinerConnectionInput
		if err = json.Unmarshal(raw, &input); err == nil {
			result, err = api.BuildMinerConnection(input)
		}
	case "xvb-standby":
		var input struct {
			Stats         json.RawMessage `json:"stats"`
			DonationLevel string          `json:"donation_level"`
		}
		if err = json.Unmarshal(raw, &input); err == nil {
			result, err = api.BuildXVBStandby(input.Stats, input.DonationLevel)
		}
	case "metrics":
		var input api.PrometheusInput
		if err = json.Unmarshal(raw, &input); err == nil {
			var body string
			body, err = api.RenderPrometheus(input)
			if err == nil {
				w.Header().Set("Content-Type", api.PrometheusContentType)
				w.Header().Set("Content-Length", strconv.Itoa(len(body)))
				w.WriteHeader(http.StatusOK)
				if r.Method != http.MethodHead {
					_, _ = w.Write([]byte(body))
				}
				return
			}
		}
	}
	if err != nil {
		h.dataFallback(w, r)
		return
	}
	body, err := json.Marshal(result)
	if err != nil {
		h.dataFallback(w, r)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	if operation == "miner-connection" {
		w.Header().Set("Cache-Control", "no-store")
	}
	w.WriteHeader(http.StatusOK)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}

func (h *handler) dataFallback(w http.ResponseWriter, r *http.Request) {
	if h.options.Reference != nil {
		h.options.Reference.ServeHTTP(w, r)
		return
	}
	writeDataError(w, r)
}

func writeDataError(w http.ResponseWriter, r *http.Request) {
	message := "Failed to build dashboard state."
	if r.URL.Path == "/metrics" {
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		w.Header().Set("Content-Length", strconv.Itoa(len("Failed to render metrics.")))
		w.WriteHeader(http.StatusInternalServerError)
		if r.Method != http.MethodHead {
			_, _ = w.Write([]byte("Failed to render metrics."))
		}
		return
	}
	if r.URL.Path == "/api/xvb-standby" {
		message = "Failed to build XvB standby state."
	}
	body, _ := json.Marshal(map[string]string{"error": message})
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Content-Length", strconv.Itoa(len(body)))
	w.WriteHeader(http.StatusInternalServerError)
	if r.Method != http.MethodHead {
		_, _ = w.Write(body)
	}
}
