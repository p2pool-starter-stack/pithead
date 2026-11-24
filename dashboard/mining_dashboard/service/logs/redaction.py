import re
from pathlib import Path

PATTERN_FILE = Path(__file__).with_name("redact.sed")
_COMMAND = re.compile(r"^s/([^/]*)/([^/]*)/g$")
_POSIX_SPACE = "[:space:]"


def load_rules(path=PATTERN_FILE):
    rules = []
    for number, line in enumerate(path.read_text().splitlines(), 1):
        match = _COMMAND.match(line)
        if not match:
            raise ValueError(f"{path.name}:{number}: not an s/PATTERN/REPLACEMENT/g command")
        pattern, replacement = match.groups()
        rules.append((re.compile(pattern.replace(_POSIX_SPACE, r"\s"), re.ASCII), replacement))
    return tuple(rules)


_RULES = load_rules()


def redact_line(line):
    for pattern, replacement in _RULES:
        line = pattern.sub(replacement, line)
    return line
