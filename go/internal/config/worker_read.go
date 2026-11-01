package config

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"strconv"
	"strings"
)

var ErrUnsupportedWorkerRead = errors.New("unsupported worker read render")

func ProjectWorkerRead(raw []byte) ([]byte, error) {
	root, err := parsePersistenceRoot(raw)
	if err != nil {
		return nil, ErrUnsupportedWorkerRead
	}
	workers, ok := objectValue(root, "workers")
	if !ok || isNull(workers) {
		workers = node{object: []member{}}
	} else if workers.object == nil {
		return nil, ErrUnsupportedWorkerRead
	}
	defaultPort, ok := objectValue(workers, "api_port")
	if !ok || isNull(defaultPort) || defaultPort.value == false {
		defaultPort = node{value: json.Number("8080")}
	}
	list, ok := objectValue(workers, "list")
	if !ok || isNull(list) || list.value == false {
		return []byte{}, nil
	}
	var entries []node
	if list.array != nil {
		entries = list.array
	} else if list.object != nil {
		entries = make([]node, 0, len(list.object))
		for _, item := range list.object {
			entries = append(entries, item.value)
		}
	} else {
		return nil, ErrUnsupportedWorkerRead
	}
	var output bytes.Buffer
	for _, entry := range entries {
		if isNull(entry) {
			continue
		}
		if entry.object == nil {
			return nil, ErrUnsupportedWorkerRead
		}
		token, ok := objectValue(entry, "token")
		if !ok {
			continue
		}
		if _, ok := token.value.(string); !ok {
			continue
		}
		name := workerReadDefault(entry, "name", node{value: ""})
		host := workerReadDefault(entry, "host", node{value: ""})
		port := workerReadDefault(entry, "port", defaultPort)
		row := node{object: []member{
			{key: "name", value: name},
			{key: "host", value: host},
			{key: "token", value: token},
			{key: "port", value: port},
		}}
		if err := writeWorkerReadCompact(&output, row); err != nil {
			return nil, err
		}
		output.WriteByte('\n')
	}
	return output.Bytes(), nil
}

func WorkerReadValues(raw []byte) ([][]byte, error) {
	root, err := parseWorkerReadDocument(raw)
	if err != nil || root.object == nil {
		return nil, ErrUnsupportedWorkerRead
	}
	values := make([][]byte, 0, 4)
	for _, key := range []string{"name", "host", "token", "port"} {
		value, ok := objectValue(root, key)
		if !ok {
			value = node{}
		}
		rendered, renderErr := workerReadRaw(value)
		if renderErr != nil || bytes.ContainsAny(rendered, "\x00\r\n") {
			return nil, ErrUnsupportedWorkerRead
		}
		values = append(values, rendered)
	}
	return values, nil
}

func WorkerReadRecord(name, host, port, read string) ([]byte, error) {
	if strings.ContainsAny(name, "\r\n") || strings.ContainsAny(host, "\r\n") || strings.ContainsAny(port, "\r\n") || strings.ContainsAny(read, "\r\n") {
		return nil, ErrUnsupportedWorkerRead
	}
	value, err := strconv.ParseUint(port, 10, 16)
	if err != nil || value == 0 {
		return nil, ErrUnsupportedWorkerRead
	}
	return prettyJQ(node{object: []member{
		{key: "name", value: node{value: name}},
		{key: "host", value: node{value: host}},
		{key: "port", value: node{value: json.Number(strconv.FormatUint(value, 10))}},
		{key: "read_token", value: node{value: read}},
	}})
}

func SlurpWorkerRead(raw []byte) ([]byte, error) {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	values := make([]node, 0)
	for {
		var encoded json.RawMessage
		err := decoder.Decode(&encoded)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return nil, ErrUnsupportedWorkerRead
		}
		value, err := parseWorkerReadDocument(encoded)
		if err != nil {
			return nil, ErrUnsupportedWorkerRead
		}
		values = append(values, value)
	}
	return prettyJQ(node{array: values})
}

func workerReadDefault(root node, key string, fallback node) node {
	value, ok := objectValue(root, key)
	if !ok || isNull(value) || value.value == false {
		return cloneNode(fallback)
	}
	return value
}

func parseWorkerReadDocument(raw []byte) (node, error) {
	document, err := ParseDocument(raw)
	if err != nil || document == nil || duplicateError(document.root, "") != "" {
		return node{}, ErrUnsupportedWorkerRead
	}
	if _, err := prettyJQ(document.root); err != nil {
		return node{}, ErrUnsupportedWorkerRead
	}
	return document.root, nil
}

func writeWorkerReadCompact(output *bytes.Buffer, current node) error {
	rendered, err := prettyJQ(current)
	if err != nil || json.Compact(output, rendered) != nil {
		return ErrUnsupportedWorkerRead
	}
	return nil
}

func workerReadRaw(current node) ([]byte, error) {
	if text, ok := current.value.(string); ok {
		return bytes.TrimRight([]byte(text), "\n"), nil
	}
	rendered, err := prettyJQ(current)
	if err != nil {
		return nil, err
	}
	return bytes.TrimSuffix(rendered, []byte{'\n'}), nil
}
