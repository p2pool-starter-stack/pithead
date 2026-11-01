# Check the raw document before jq can discard repeated members, or a config rewrite can
# hide them. The distributed CLI is self-contained, so this parser is embedded here.
config_document_error() { # <file> [request: check placeholders only in .config]
    local native_binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}" native_reason native_rc=0
    if [ "${PITHEAD_IMPL:-}" = go ]; then native_binary="${PITHEAD_GO_BINARY:-$native_binary}"; fi
    if [ -n "$native_binary" ] && [ -x "$native_binary" ] && command -v python3 >/dev/null 2>&1; then
        native_reason=$(PITHEAD_GO_HELPER=config-document "$native_binary" "$1" "${2:-config}" 2>/dev/null) || native_rc=$?
        case "$native_rc" in
        0 | 1)
            [ -z "$native_reason" ] || printf '%s\n' "$native_reason"
            return "$native_rc"
            ;;
        esac
    fi
    python3 - "$1" "${2:-config}" <<'PYDOC'
import json


class _ObjectPairs(list):
    """Keep object members until their paths and duplicate keys have been checked."""


def _path(parent, key):
    key = json.dumps(key, ensure_ascii=True)[1:-1].replace('\\"', '"')
    return f"{parent}.{key}" if parent else key


def _decode(node, path=""):
    if isinstance(node, _ObjectPairs):
        result = {}
        for key, value in node:
            if key in result:
                location = path or "the top level"
                raise ValueError(
                    f"duplicate key {json.dumps(key)} at {location} "
                    f"(path {_path(path, key)})"
                )
            result[key] = _decode(value, _path(path, key))
        return result
    if isinstance(node, list):
        return [_decode(value, f"{path}[{index}]") for index, value in enumerate(node)]
    return node


def reject_placeholders(node, path=""):
    """Reject template instructions in every string leaf; never print its value."""
    if isinstance(node, dict):
        for key, value in node.items():
            reject_placeholders(value, _path(path, key))
    elif isinstance(node, list):
        for index, value in enumerate(node):
            reject_placeholders(value, f"{path}[{index}]")
    elif isinstance(node, str) and node.upper().startswith(("PASTE_", "YOUR_")):
        raise ValueError(f"placeholder value at {path or 'the top level'}")


def loads(text):
    """Decode JSON without silently replacing any repeated object member."""
    return _decode(json.loads(text, object_pairs_hook=_ObjectPairs))

import sys

try:
    with open(sys.argv[1], encoding="utf-8") as stream:
        document = loads(stream.read())
    candidate = document.get("config", {}) if sys.argv[2] == "request" and isinstance(document, dict) else document
    reject_placeholders(candidate)
except (OSError, ValueError, RecursionError) as exc:
    if isinstance(exc, json.JSONDecodeError):
        message = "not valid JSON"
    elif isinstance(exc, OSError):
        message = "could not read config document"
    elif isinstance(exc, RecursionError):
        message = "config document is nested too deeply"
    else:
        message = str(exc)
    # Paths are untrusted too: escape control characters rather than injecting terminal lines.
    print(message)
    sys.exit(1)
PYDOC
}

validate_config_document() {
    local reason
    command -v python3 >/dev/null 2>&1 || error "Config validation requires python3. Install it and retry."
    if ! reason=$(config_document_error "$CONFIG_FILE"); then
        error "Invalid configuration: $reason."
    fi
}

validate_config_control_characters() {
    local native_rc=0
    _config_validation_go controls >/dev/null 2>&1 || native_rc=$?
    [ "$native_rc" -ne 0 ] || return 0
    if [ "$native_rc" -eq 1 ] || jq -e 'any(.. | strings; test("[[:cntrl:]]"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        error "$CONFIG_FILE has a config value containing a control character or newline. That is not allowed — it could inject an extra line into the stack's .env. Remove the newline/control character (check secrets like node_password, bot_token, api_token)."
    fi
}

_config_validation_go() {
    local binary="${PITHEAD_GO_CONFIG_DOCUMENT_BINARY:-}"
    if [ "${PITHEAD_IMPL:-}" = go ]; then binary="${PITHEAD_GO_BINARY:-$binary}"; fi
    [ -n "$binary" ] && [ -x "$binary" ] && command -v jq >/dev/null 2>&1 || return 125
    PITHEAD_GO_HELPER=config-validation "$binary" "$1" "$CONFIG_FILE"
}
