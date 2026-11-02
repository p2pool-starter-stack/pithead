package fleet

import (
	"encoding/json"
	"errors"
	"strconv"
)

type pollLifecycleState struct {
	name  any
	state map[string]any
	seen  bool
}

type pollLifecycleKey struct {
	nilName bool
	name    string
}

type pollProbeKey struct {
	name string
	ip   string
}

func pollLifecycle(request Request) (any, error) {
	values, err := detailArguments(request, 3)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	records, err := array(values[1])
	if err != nil {
		return nil, err
	}
	falloff, err := pollFloat(values[2])
	if err != nil {
		return nil, err
	}
	states := make([]pollLifecycleState, 0, len(records)+len(workers))
	stateIndexes := make(map[pollLifecycleKey]int, len(records)+len(workers))
	for _, value := range records {
		pair, err := array(value)
		if err != nil || len(pair) != 2 {
			return nil, errors.New("invalid lifecycle state record")
		}
		state, err := object(pair[1])
		if err != nil {
			return nil, err
		}
		key, err := lifecycleKey(pair[0])
		if err != nil {
			return nil, err
		}
		if _, err := required(state, "connected_since"); err != nil {
			return nil, err
		}
		if _, err := required(state, "last_active"); err != nil {
			return nil, err
		}
		if _, exists := stateIndexes[key]; exists {
			return nil, errors.New("duplicate lifecycle state name")
		}
		stateIndexes[key] = len(states)
		states = append(states, pollLifecycleState{name: pair[0], state: state})
	}
	patches := make([]any, len(workers))
	liveIndices := []any{}
	for index, value := range workers {
		worker, err := object(value)
		if err != nil {
			return nil, err
		}
		name := member(worker, "name", nil)
		key, err := lifecycleKey(name)
		if err != nil {
			return nil, err
		}
		stateIndex, exists := stateIndexes[key]
		if !exists {
			stateIndex = len(states)
			stateIndexes[key] = stateIndex
			states = append(states, pollLifecycleState{name: name, state: map[string]any{"connected_since": nil, "last_active": 0.0}})
		}
		state := &states[stateIndex]
		state.seen = true
		patch := map[string]any{}
		if member(worker, "status", nil) == "online" {
			if state.state["connected_since"] == nil {
				state.state["connected_since"] = request.Now
			}
			state.state["last_active"] = request.Now
			if !truthy(member(worker, "uptime", nil)) {
				connected, err := pollFloat(state.state["connected_since"])
				if err != nil {
					return nil, err
				}
				patch["uptime"], err = pollTruncatedInteger(request.Now - connected)
				if err != nil {
					return nil, err
				}
			}
			liveIndices = append(liveIndices, json.Number(strconv.Itoa(index)))
		} else {
			state.state["connected_since"] = nil
			lastActive, err := pollFloat(member(state.state, "last_active", nil))
			if err != nil {
				return nil, err
			}
			if lastActive == 0 {
				lastActive = request.Now
				state.state["last_active"] = request.Now
			}
			if request.Now-lastActive <= falloff {
				liveIndices = append(liveIndices, json.Number(strconv.Itoa(index)))
			}
		}
		patches[index] = patch
	}
	stateOutput := []any{}
	for _, state := range states {
		if state.seen {
			stateOutput = append(stateOutput, []any{state.name, state.state})
		}
	}
	return map[string]any{"patches": patches, "live_indices": liveIndices, "state": stateOutput}, nil
}

func lifecycleKey(value any) (pollLifecycleKey, error) {
	if value == nil {
		return pollLifecycleKey{nilName: true}, nil
	}
	name, ok := value.(string)
	if !ok {
		return pollLifecycleKey{}, errors.New("invalid lifecycle name")
	}
	return pollLifecycleKey{name: name}, nil
}

func pollProbePlan(request Request) (any, error) {
	values, err := detailArguments(request, 2)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	answered, err := array(values[1])
	if err != nil {
		return nil, err
	}
	answeredSet := make(map[pollProbeKey]struct{}, len(answered))
	for _, raw := range answered {
		pair, err := array(raw)
		if err != nil || len(pair) != 2 {
			return nil, errors.New("invalid answered worker pair")
		}
		name, nameOK := pair[0].(string)
		if !nameOK {
			return nil, errors.New("invalid answered worker name")
		}
		ip, ipOK := pair[1].(string)
		if !ipOK {
			return nil, errors.New("invalid answered worker ip")
		}
		answeredSet[pollProbeKey{name: name, ip: ip}] = struct{}{}
	}
	result := make([]any, len(workers))
	for index, value := range workers {
		worker, err := object(value)
		if err != nil {
			return nil, err
		}
		name, err := required(worker, "name")
		if err != nil {
			return nil, err
		}
		ip, err := required(worker, "ip")
		if err != nil {
			return nil, err
		}
		nameText, ok := name.(string)
		if !ok {
			return nil, errors.New("invalid probe worker name")
		}
		ipText, ok := ip.(string)
		if !ok {
			return nil, errors.New("invalid probe worker ip")
		}
		wanted := member(worker, "status", nil) == "online"
		_, previouslyAnswered := answeredSet[pollProbeKey{name: nameText, ip: ipText}]
		wanted = wanted || previouslyAnswered
		result[index] = wanted
	}
	return result, nil
}

func pollProbeComplete(request Request) (any, error) {
	values, err := detailArguments(request, 3)
	if err != nil {
		return nil, err
	}
	workers, err := array(values[0])
	if err != nil {
		return nil, err
	}
	wanted, err := array(values[1])
	if err != nil || len(wanted) != len(workers) {
		return nil, errors.New("invalid probe plan")
	}
	probed, err := array(values[2])
	if err != nil {
		return nil, err
	}
	indices := make([]any, len(workers))
	answered := []any{}
	next := 0
	for index, value := range workers {
		if !truthy(wanted[index]) {
			indices[index] = nil
			continue
		}
		if next >= len(probed) {
			return nil, errors.New("missing probed worker result")
		}
		result, err := object(probed[next])
		if err != nil {
			return nil, err
		}
		next++
		indices[index] = json.Number(strconv.Itoa(next - 1))
		if truthy(member(result, "api_ok", nil)) {
			worker, err := object(value)
			if err != nil {
				return nil, err
			}
			name, err := required(worker, "name")
			if err != nil {
				return nil, err
			}
			ip, err := required(worker, "ip")
			if err != nil {
				return nil, err
			}
			if _, ok := name.(string); !ok {
				return nil, errors.New("invalid probe worker name")
			}
			if _, ok := ip.(string); !ok {
				return nil, errors.New("invalid probe worker ip")
			}
			answered = append(answered, []any{name, ip})
		}
	}
	if next != len(probed) {
		return nil, errors.New("extra probed worker result")
	}
	return map[string]any{"result_indices": indices, "answered": answered}, nil
}
