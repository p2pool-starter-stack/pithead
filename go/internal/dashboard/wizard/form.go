package wizard

import (
	"bufio"
	"bytes"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
)

type Field struct {
	Text         string          `json:"text"`
	RawString    *string         `json:"raw_string"`
	Present      bool            `json:"present"`
	Truth        bool            `json:"truth"`
	Lower        string          `json:"lower"`
	Digit        bool            `json:"digit"`
	Integer      json.RawMessage `json:"integer"`
	IntegerError string          `json:"integer_error"`
}

type FormRequest struct {
	Operation   string           `json:"operation"`
	Defaults    map[string]any   `json:"defaults"`
	Fields      map[string]Field `json:"fields"`
	TariDefault string           `json:"tari_default"`
	Disks       []map[string]any `json:"disks"`
}

type FormOperation struct {
	Path  []string `json:"path"`
	Value any      `json:"value,omitempty"`
	Pairs [][2]any `json:"pairs,omitempty"`
}

type ValidationError struct{ Message string }

func (e ValidationError) Error() string { return e.Message }

type formKeyError struct{ key string }

func (e formKeyError) Error() string { return fmt.Sprintf("'%s'", e.key) }

func RunForm(input io.Reader, output io.Writer) error {
	scanner := bufio.NewScanner(input)
	scanner.Buffer(make([]byte, 4096), 64<<20)
	for scanner.Scan() {
		var request FormRequest
		decoder := json.NewDecoder(bytes.NewReader(scanner.Bytes()))
		decoder.UseNumber()
		response := Response{}
		if err := decoder.Decode(&request); err != nil {
			response.Error = wireError(err)
		} else {
			var value any
			var err error
			switch request.Operation {
			case "build":
				value, err = BuildConfigPlan(request)
			case "install":
				value, err = ValidateInstallRequest(request.Fields, request.Disks)
			default:
				err = ValidationError{fmt.Sprintf("unsupported wizard form operation: %s", request.Operation)}
			}
			if err != nil {
				var validation ValidationError
				var key formKeyError
				if errors.As(err, &validation) {
					response.Error = &Error{Kind: "ValueError", Message: err.Error()}
				} else if errors.As(err, &key) {
					response.Error = &Error{Kind: "KeyError", Message: err.Error()}
				} else {
					response.Error = wireError(err)
				}
			} else if raw, marshalErr := json.Marshal(value); marshalErr != nil {
				response.Error = wireError(marshalErr)
			} else {
				response = Response{OK: true, Value: raw}
			}
		}
		if err := writeResponse(output, response); err != nil {
			return err
		}
	}
	return scanner.Err()
}

func BuildConfigPlan(request FormRequest) ([]FormOperation, error) {
	field := func(name string) Field { return request.Fields[name] }
	equals := func(name, value string) bool {
		raw := field(name).RawString
		return raw != nil && *raw == value
	}
	value := func(name string) string { return field(name).Text }
	fallback := func(name, path string) any {
		if text := value(name); text != "" {
			return text
		}
		return request.Defaults[path]
	}
	port := func(name, path string) (any, error) {
		input := field(name)
		if !input.Digit {
			return request.Defaults[path], nil
		}
		if input.IntegerError != "" {
			return nil, ValidationError{input.IntegerError}
		}
		if len(input.Integer) == 0 {
			return nil, ValidationError{"missing integer value"}
		}
		var number json.Number
		if err := json.Unmarshal(input.Integer, &number); err != nil {
			return nil, err
		}
		return number, nil
	}
	password := request.Defaults["p2pool.stratum_password"]
	if equals("stratum_password", "true") {
		bytes := make([]byte, 12)
		if _, err := rand.Read(bytes); err != nil {
			return nil, err
		}
		password = hex.EncodeToString(bytes)
	}
	moneroMode := fallback("monero_mode", "monero.mode")
	tariMode := any(value("tari_mode"))
	if tariMode == "" {
		if request.TariDefault != "" {
			tariMode = request.TariDefault
		} else {
			tariMode = request.Defaults["tari.mode"]
		}
	}
	ops := []FormOperation{
		set([]string{"dashboard", "host"}, fallback("machine_name", "dashboard.host")),
		set([]string{"monero", "wallet_address"}, value("monero_wallet")),
		set([]string{"monero", "mode"}, moneroMode),
		pairs([]string{"p2pool"}, [2]any{"pool", fallback("pool", "p2pool.pool")}, [2]any{"stratum_password", password}),
		set([]string{"tari", "mode"}, tariMode),
	}
	if tariMode != "off" {
		ops = append(ops, set([]string{"tari", "wallet_address"}, value("tari_wallet")))
	}
	if equals("monero_mode", "remote") {
		rpc, err := port("monero_remote_rpc", "monero.remote.rpc_port")
		if err != nil {
			return nil, err
		}
		zmq, err := port("monero_remote_zmq", "monero.remote.zmq_port")
		if err != nil {
			return nil, err
		}
		ops = append(ops,
			set([]string{"monero", "mode"}, "remote"),
			pairs([]string{"monero", "remote"}, [2]any{"host", value("monero_remote_host")}, [2]any{"rpc_port", rpc}, [2]any{"zmq_port", zmq}),
		)
		if field("monero_remote_auth").Truth {
			ops = append(ops,
				set([]string{"monero", "node_username"}, value("monero_remote_user")),
				set([]string{"monero", "node_password"}, value("monero_remote_pass")),
			)
		}
	}
	if tariMode == "remote" {
		grpc, err := port("tari_remote_grpc", "tari.remote.grpc_port")
		if err != nil {
			return nil, err
		}
		ops = append(ops, pairs([]string{"tari", "remote"}, [2]any{"host", value("tari_remote_host")}, [2]any{"grpc_port", grpc}))
	}
	if !equals("monero_mode", "remote") && equals("prune", "false") {
		ops = append(ops, set([]string{"monero", "prune"}, false))
	}
	if healthchecks := value("healthchecks_url"); healthchecks != "" {
		ops = append(ops, pairs([]string{"healthchecks"}, [2]any{"ping_url", healthchecks}))
	}
	if token, chat := value("telegram_token"), value("telegram_chat"); token != "" && chat != "" {
		ops = append(ops, pairs([]string{"telegram"}, [2]any{"enabled", true}, [2]any{"bot_token", token}, [2]any{"chat_id", chat}))
	}
	if equals("role", "pithead") || equals("role", "both") {
		ops = append(ops, set([]string{"local_miner", "enabled"}, equals("role", "both")))
	}
	if field("local_miner").Present {
		lower := field("local_miner").Lower
		ops = append(ops, set([]string{"local_miner", "enabled"}, lower == "on" || lower == "true" || lower == "1"))
	}
	fast := equals("clearnet_sync", "true")
	ops = append(ops,
		set([]string{"monero", "clearnet_initial_sync"}, fast && moneroMode == "local"),
		set([]string{"tari", "clearnet_initial_sync"}, fast && tariMode == "local"),
	)
	if timezone := value("timezone"); timezone != "" && timezone != request.Defaults["dashboard.timezone"] {
		ops = append(ops, set([]string{"dashboard", "timezone"}, timezone))
	}
	return ops, nil
}

func ValidateInstallRequest(fields map[string]Field, disks []map[string]any) (map[string]any, error) {
	disk := fields["disk"].Text
	confirm := fields["confirm"].Text
	wipe := fields["wipe"].Text
	if wipe == "" {
		wipe = "keep"
	}
	var selected map[string]any
	for _, item := range disks {
		name, ok := item["name"]
		if !ok {
			return nil, formKeyError{"name"}
		}
		if name, ok := name.(string); ok && name == disk {
			selected = item
		}
	}
	if selected == nil {
		return nil, ValidationError{"choose a disk from the list"}
	}
	if confirm != disk {
		return nil, ValidationError{fmt.Sprintf("type %s exactly to confirm", disk)}
	}
	if wipe != "keep" && wipe != "data" && wipe != "all" {
		return nil, ValidationError{"unknown wipe mode"}
	}
	if wipe != "keep" {
		state, ok := selected["state"]
		if !ok {
			return nil, formKeyError{"state"}
		}
		if state != "pithead-with-data" {
			wipe = "keep"
		}
	}
	return map[string]any{"disk": disk, "wipe": wipe}, nil
}

func set(path []string, value any) FormOperation { return FormOperation{Path: path, Value: value} }

func pairs(path []string, values ...[2]any) FormOperation {
	return FormOperation{Path: path, Pairs: values}
}
