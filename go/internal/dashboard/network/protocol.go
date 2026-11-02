package network

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"unicode/utf8"
)

const maxRequestBytes = 2 << 20

type policyRequest struct {
	Operation           string  `json:"operation"`
	Firewall            *bool   `json:"firewall"`
	P2PoolClearnet      *bool   `json:"p2pool_clearnet"`
	XVBEnabled          *bool   `json:"xvb_enabled"`
	XVBTor              *bool   `json:"xvb_tor"`
	MoneroClearnetSync  *bool   `json:"monero_clearnet_sync"`
	TariClearnetSync    *bool   `json:"tari_clearnet_sync"`
	MoneroRoute         *string `json:"monero_route"`
	TariRoute           *string `json:"tari_route"`
	TariEnabled         *bool   `json:"tari_enabled"`
	HealthchecksEnabled *bool   `json:"healthchecks_enabled"`
	TelegramEnabled     *bool   `json:"telegram_enabled"`
	PriceFeedEnabled    *bool   `json:"price_feed_enabled"`
	NotifySinksEnabled  *bool   `json:"notify_sinks_enabled"`
	NotifyTor           *bool   `json:"notify_tor"`
	NotifySinksPrivate  *bool   `json:"notify_sinks_private"`
	StandbyRoute        *string `json:"standby_route"`
	TorAutoHeal         *bool   `json:"tor_auto_heal"`
	TariExplorer        *bool   `json:"tari_explorer"`
}

type edgeRequest struct {
	policyRequest
	LocalMinerEnabled *bool   `json:"local_miner_enabled"`
	StratumLabel      *string `json:"stratum_label"`
}

type nodeRequest struct {
	Operation         string  `json:"operation"`
	Nodes             *[]Node `json:"nodes"`
	MoneroRoute       *string `json:"monero_route"`
	TariRoute         *string `json:"tari_route"`
	TariEnabled       *bool   `json:"tari_enabled"`
	LocalMinerEnabled *bool   `json:"local_miner_enabled"`
}

type statusValidityRequest struct {
	Operation string       `json:"operation"`
	RC        numericValue `json:"rc"`
	CheckedAt numericValue `json:"checked_at"`
}

type statusResultRequest struct {
	Operation string       `json:"operation"`
	RC        numericValue `json:"rc"`
	Age       numericValue `json:"age"`
}

type firewallPlanRequest struct {
	Operation  string  `json:"operation"`
	Configured *bool   `json:"configured"`
	State      *string `json:"state"`
}

type operationRequest struct {
	Operation string `json:"operation"`
}

type wireError struct {
	Kind    string `json:"kind"`
	Message string `json:"message"`
}

type wireResponse struct {
	OK    bool       `json:"ok"`
	Value any        `json:"value,omitempty"`
	Error *wireError `json:"error,omitempty"`
}

func Run(input io.Reader, output io.Writer) error {
	raw, err := io.ReadAll(io.LimitReader(input, maxRequestBytes+1))
	if err != nil {
		return err
	}
	var value any
	if len(raw) > maxRequestBytes {
		err = errors.New("network request exceeds size limit")
	} else {
		value, err = build(raw)
	}
	response := wireResponse{OK: err == nil, Value: value}
	if err != nil {
		response.Error = &wireError{Kind: "ValueError", Message: err.Error()}
	}
	return json.NewEncoder(output).Encode(response)
}

func build(raw []byte) (any, error) {
	if !utf8.Valid(raw) {
		return nil, errors.New("network request is not valid UTF-8")
	}
	var operation operationRequest
	if err := decodeComplete(raw, &operation, false); err != nil {
		return nil, err
	}
	switch operation.Operation {
	case "posture":
		var request policyRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		input, err := request.input()
		if err != nil {
			return nil, err
		}
		return buildPosture(input), nil
	case "topology-edges":
		var request edgeRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		input, err := request.policyRequest.input()
		if err != nil {
			return nil, err
		}
		if request.LocalMinerEnabled == nil || request.StratumLabel == nil {
			return nil, errors.New("missing topology edge input")
		}
		if len(*request.StratumLabel) > 256 {
			return nil, errors.New("stratum label exceeds size limit")
		}
		input.LocalMinerEnabled = *request.LocalMinerEnabled
		input.StratumLabel = *request.StratumLabel
		return buildEdges(input), nil
	case "topology-nodes":
		var request nodeRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		if request.Nodes == nil || request.MoneroRoute == nil || request.TariRoute == nil || request.TariEnabled == nil || request.LocalMinerEnabled == nil {
			return nil, errors.New("missing topology node input")
		}
		if len(*request.Nodes) > 4096 {
			return nil, errors.New("topology node count exceeds limit")
		}
		if err := validateRoute(*request.MoneroRoute); err != nil {
			return nil, err
		}
		if err := validateRoute(*request.TariRoute); err != nil {
			return nil, err
		}
		for _, node := range *request.Nodes {
			if len(node.ID) > 256 || len(node.Zone) > 256 {
				return nil, errors.New("topology node field exceeds size limit")
			}
		}
		return buildNodePlan(*request.Nodes, *request.MoneroRoute, *request.TariRoute, *request.TariEnabled, *request.LocalMinerEnabled), nil
	case "firewall-status-valid":
		var request statusValidityRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		return statusFieldsValid(request.RC, request.CheckedAt)
	case "firewall-status-result":
		var request statusResultRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		return firewallState(request.RC, request.Age)
	case "firewall-plan":
		var request firewallPlanRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		if request.Configured == nil || request.State == nil {
			return nil, errors.New("missing firewall plan input")
		}
		return buildFirewallPlan(*request.Configured, *request.State)
	case "control-outcomes":
		var request outcomeRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		return controlOutcomes(request)
	case "audit-cap-policy":
		var request auditCapRequest
		if err := decodeComplete(raw, &request, true); err != nil {
			return nil, err
		}
		return buildAuditCapPolicy(request)
	default:
		return nil, fmt.Errorf("unsupported network operation: %s", operation.Operation)
	}
}

func (request policyRequest) input() (policyInput, error) {
	if request.Firewall == nil || request.P2PoolClearnet == nil || request.XVBEnabled == nil || request.XVBTor == nil ||
		request.MoneroClearnetSync == nil || request.TariClearnetSync == nil || request.MoneroRoute == nil || request.TariRoute == nil ||
		request.TariEnabled == nil || request.HealthchecksEnabled == nil || request.TelegramEnabled == nil || request.PriceFeedEnabled == nil ||
		request.NotifySinksEnabled == nil || request.NotifyTor == nil || request.NotifySinksPrivate == nil || request.StandbyRoute == nil ||
		request.TorAutoHeal == nil || request.TariExplorer == nil {
		return policyInput{}, errors.New("missing network policy input")
	}
	if err := validateRoute(*request.MoneroRoute); err != nil {
		return policyInput{}, err
	}
	if err := validateRoute(*request.TariRoute); err != nil {
		return policyInput{}, err
	}
	if err := validateRoute(*request.StandbyRoute); err != nil {
		return policyInput{}, errors.New("invalid standby route")
	}
	return policyInput{
		Firewall: *request.Firewall, P2PoolClearnet: *request.P2PoolClearnet, XVBEnabled: *request.XVBEnabled, XVBTor: *request.XVBTor,
		MoneroClearnetSync: *request.MoneroClearnetSync, TariClearnetSync: *request.TariClearnetSync,
		MoneroRoute: *request.MoneroRoute, TariRoute: *request.TariRoute, TariEnabled: *request.TariEnabled,
		HealthchecksEnabled: *request.HealthchecksEnabled, TelegramEnabled: *request.TelegramEnabled, PriceFeedEnabled: *request.PriceFeedEnabled,
		NotifySinksEnabled: *request.NotifySinksEnabled, NotifyTor: *request.NotifyTor, NotifySinksPrivate: *request.NotifySinksPrivate,
		StandbyRoute: *request.StandbyRoute, TorAutoHeal: *request.TorAutoHeal, TariExplorer: *request.TariExplorer,
	}, nil
}

func validateRoute(route string) error {
	if route != routeLocal && route != routeLAN && route != routeClearnet && route != routeUnknown &&
		route != routeTor && route != routeIncoming && route != routeInactive {
		return errors.New("invalid route")
	}
	return nil
}

func decodeComplete(raw []byte, value any, strict bool) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if strict {
		decoder.DisallowUnknownFields()
	}
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var trailing any
	if err := decoder.Decode(&trailing); !errors.Is(err, io.EOF) {
		if err == nil {
			return errors.New("multiple network requests")
		}
		return err
	}
	return nil
}
