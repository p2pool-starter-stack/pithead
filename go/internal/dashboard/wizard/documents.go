package wizard

import (
	"fmt"
	"strconv"
	"strings"
)

type DocumentField struct {
	Key     *ConfigValue  `json:"key"`
	KeyJSON *ConfigValue  `json:"key_json"`
	Value   *DocumentNode `json:"value"`
}

type DocumentNode struct {
	Kind     string          `json:"kind"`
	Fields   []DocumentField `json:"fields"`
	Items    []*DocumentNode `json:"items"`
	Value    *ConfigValue    `json:"value"`
	Identity int             `json:"identity"`
}

type DocumentRequest struct {
	Operation string        `json:"operation"`
	Node      *DocumentNode `json:"node"`
	Path      *ConfigValue  `json:"path"`
	Key       *ConfigValue  `json:"key"`
	KeyJSON   *ConfigValue  `json:"key_json"`
}

type DocumentFault struct {
	Kind       string       `json:"kind"`
	Path       *ConfigValue `json:"path"`
	Key        *ConfigValue `json:"key"`
	Diagnostic *ConfigValue `json:"diagnostic"`
}

type DocumentResult struct {
	Value   *ConfigValue    `json:"value,omitempty"`
	Fault   *DocumentFault  `json:"fault,omitempty"`
	Aliases []DocumentAlias `json:"aliases,omitempty"`
}

type DocumentAlias struct {
	Path     []*ConfigValue `json:"path"`
	Identity int            `json:"identity"`
}

func handleDocumentRequest(request DocumentRequest) (DocumentResult, error) {
	switch request.Operation {
	case "decode":
		path, err := optionalDocumentPath(request.Path)
		if err != nil {
			return DocumentResult{}, err
		}
		return decodeDocument(request.Node, path)
	case "placeholders":
		path, err := optionalDocumentPath(request.Path)
		if err != nil {
			return DocumentResult{}, err
		}
		fault, err := placeholderDocumentNode(request.Node, path)
		return DocumentResult{Fault: fault}, err
	case "path":
		parent, err := documentString(request.Path, "path")
		if err != nil {
			return DocumentResult{}, err
		}
		path, err := documentFieldPath(parent, request.Key, request.KeyJSON)
		return DocumentResult{Value: documentText(path)}, err
	case "diagnostic":
		path, err := documentString(request.Path, "path")
		if err != nil {
			return DocumentResult{}, err
		}
		placeholder := request.KeyJSON == nil && (request.Key == nil || request.Key.Kind == "null")
		if placeholder {
			return DocumentResult{Value: documentText(fmt.Sprintf("placeholder value at %s", documentLocation(path)))}, nil
		}
		dumped, err := documentDump(request.Key, request.KeyJSON)
		if err != nil {
			return DocumentResult{}, err
		}
		childPath, err := documentFieldPath(path, request.Key, request.KeyJSON)
		if err != nil {
			return DocumentResult{}, err
		}
		diagnostic := fmt.Sprintf("duplicate key %s at %s (path %s)", dumped, documentLocation(path), childPath)
		return DocumentResult{Value: documentText(diagnostic)}, nil
	case "host":
		value, fault, err := decodeDocumentNode(request.Node, "")
		if err != nil || fault != nil {
			return DocumentResult{Fault: fault}, err
		}
		if reason, ok := value.Field("_config_document_error"); ok {
			message := "Invalid host configuration"
			if reason.Kind == "str" {
				message = reason.Text
			}
			return DocumentResult{Fault: &DocumentFault{Kind: "HostConfigError", Diagnostic: documentText(message)}}, nil
		}
		return DocumentResult{Value: value}, nil
	default:
		return DocumentResult{}, ValidationError{Message: fmt.Sprintf("unsupported wizard documents operation: %s", request.Operation)}
	}
}

func placeholderDocumentNode(node *DocumentNode, path string) (*DocumentFault, error) {
	if node == nil {
		return nil, ValidationError{Message: "document node is required"}
	}
	switch node.Kind {
	case "value":
		if node.Value == nil {
			return nil, ValidationError{Message: "document value is required"}
		}
		return placeholderFault(node.Value, path)
	case "array":
		for index, child := range node.Items {
			if fault, err := placeholderDocumentNode(child, fmt.Sprintf("%s[%d]", path, index)); fault != nil || err != nil {
				return fault, err
			}
		}
	case "object":
		for _, field := range node.Fields {
			childPath, err := documentFieldPath(path, field.Key, field.KeyJSON)
			if err != nil {
				return nil, err
			}
			if fault, err := placeholderDocumentNode(field.Value, childPath); fault != nil || err != nil {
				return fault, err
			}
		}
	default:
		return nil, ValidationError{Message: fmt.Sprintf("invalid document node kind %q", node.Kind)}
	}
	return nil, nil
}

func decodeDocument(node *DocumentNode, path string) (DocumentResult, error) {
	value, fault, err := decodeDocumentNode(node, path)
	if err != nil || fault != nil {
		return DocumentResult{Value: value, Fault: fault}, err
	}
	aliases, err := documentAliases(node, nil)
	return DocumentResult{Value: value, Aliases: aliases}, err
}

func documentAliases(node *DocumentNode, path []*ConfigValue) ([]DocumentAlias, error) {
	switch node.Kind {
	case "value":
		if node.Identity == 0 {
			return nil, nil
		}
		if path == nil {
			path = []*ConfigValue{}
		}
		return []DocumentAlias{{Path: path, Identity: node.Identity}}, nil
	case "array":
		var aliases []DocumentAlias
		for index, child := range node.Items {
			childPath := appendDocumentSegment(path, &ConfigValue{Kind: "int", Text: strconv.Itoa(index)})
			childAliases, err := documentAliases(child, childPath)
			if err != nil {
				return nil, err
			}
			aliases = append(aliases, childAliases...)
		}
		return aliases, nil
	case "object":
		var aliases []DocumentAlias
		for _, field := range node.Fields {
			key, err := documentString(field.Key, "object key")
			if err != nil {
				return nil, err
			}
			childPath := appendDocumentSegment(path, documentText(key))
			childAliases, err := documentAliases(field.Value, childPath)
			if err != nil {
				return nil, err
			}
			aliases = append(aliases, childAliases...)
		}
		return aliases, nil
	default:
		return nil, ValidationError{Message: fmt.Sprintf("invalid document node kind %q", node.Kind)}
	}
}

func appendDocumentSegment(path []*ConfigValue, segment *ConfigValue) []*ConfigValue {
	child := make([]*ConfigValue, len(path), len(path)+1)
	copy(child, path)
	return append(child, segment)
}

func decodeDocumentNode(node *DocumentNode, path string) (*ConfigValue, *DocumentFault, error) {
	if node == nil {
		return nil, nil, ValidationError{Message: "document node is required"}
	}
	switch node.Kind {
	case "value":
		if node.Value == nil {
			return nil, nil, ValidationError{Message: "document value is required"}
		}
		return node.Value.Clone(), nil, nil
	case "array":
		items := make([]*ConfigValue, 0, len(node.Items))
		for index, child := range node.Items {
			value, fault, err := decodeDocumentNode(child, fmt.Sprintf("%s[%d]", path, index))
			if err != nil || fault != nil {
				return nil, fault, err
			}
			items = append(items, value)
		}
		return &ConfigValue{Kind: "list", Items: items}, nil, nil
	case "object":
		fields := make([]ConfigField, 0, len(node.Fields))
		seen := make(map[string]struct{}, len(node.Fields))
		for _, field := range node.Fields {
			key, err := documentString(field.Key, "object key")
			if err != nil {
				return nil, nil, err
			}
			if _, ok := seen[key]; ok {
				fault, err := duplicateDocumentFault(path, key)
				return nil, fault, err
			}
			childPath, err := documentPath(path, key)
			if err != nil {
				return nil, nil, err
			}
			value, fault, err := decodeDocumentNode(field.Value, childPath)
			if err != nil || fault != nil {
				return nil, fault, err
			}
			seen[key] = struct{}{}
			fields = append(fields, ConfigField{Key: key, Value: value})
		}
		return &ConfigValue{Kind: "dict", Fields: fields}, nil, nil
	default:
		return nil, nil, ValidationError{Message: fmt.Sprintf("invalid document node kind %q", node.Kind)}
	}
}

func placeholderFault(value *ConfigValue, path string) (*DocumentFault, error) {
	switch value.Kind {
	case "dict":
		for _, field := range value.Fields {
			childPath, err := documentPath(path, field.Key)
			if err != nil {
				return nil, err
			}
			if fault, err := placeholderFault(field.Value, childPath); fault != nil || err != nil {
				return fault, err
			}
		}
	case "list":
		for index, item := range value.Items {
			if fault, err := placeholderFault(item, fmt.Sprintf("%s[%d]", path, index)); fault != nil || err != nil {
				return fault, err
			}
		}
	case "str":
		upper := pythonUpper(value.Text)
		if strings.HasPrefix(upper, "PASTE_") || strings.HasPrefix(upper, "YOUR_") {
			return configDocumentFault(path, nil, fmt.Sprintf("placeholder value at %s", documentLocation(path))), nil
		}
	}
	return nil, nil
}

func duplicateDocumentFault(path, key string) (*DocumentFault, error) {
	dumped, err := documentJSONString(key)
	if err != nil {
		return nil, err
	}
	childPath, err := documentPath(path, key)
	if err != nil {
		return nil, err
	}
	diagnostic := fmt.Sprintf("duplicate key %s at %s (path %s)", dumped, documentLocation(path), childPath)
	return configDocumentFault(path, documentText(key), diagnostic), nil
}

func configDocumentFault(path string, key *ConfigValue, diagnostic string) *DocumentFault {
	return &DocumentFault{Kind: "ConfigDocumentError", Path: documentText(path), Key: key, Diagnostic: documentText(diagnostic)}
}

func documentLocation(path string) string {
	if path == "" {
		return "the top level"
	}
	return path
}
