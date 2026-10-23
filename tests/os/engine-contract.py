# ruff: noqa: S603, S607
import argparse
import itertools
import json
import re
import shlex
import subprocess
from pathlib import Path

COMMAND = re.compile(
    r'(?:^|\$\(|[;(])\s*(?:if\s+)?!?\s*(docker|"\$engine")\s+(ps\b|inspect\b|compose\s+ps\b)'
)
OPERANDS = {
    "c",
    "s",
    "svc",
    "service",
    "container",
    "cid",
    "ids",
    "id",
    "name",
    "1",
    "legacy",
    "project",
    "PWD",
}
OPTIONS = {"--filter", "--format", "-f", "--status", "--type"}
FLAGS = {"--all", "-a", "--quiet", "-q", "-aq", "--no-trunc"}


def words(text):
    lexer = shlex.shlex(text, posix=True, punctuation_chars="();|&<>")
    lexer.whitespace_split = True
    result = []
    for word in lexer:
        if word in (")", ";", "|", "||", "&&", "&", ">", "<", "):") or re.fullmatch(
            r"[|&();<>]+", word
        ):
            break
        if word in ("2", "1"):
            continue
        if word.startswith("${{"):
            word = word[1:].replace("\\t", "\t")
        result.append(word)
    return result


def expand(tokens, source, wrapper=False):
    choices = []
    for word in tokens:
        variables = re.findall(r"\$(?:\{([^}]+)\}|([A-Za-z_][A-Za-z_0-9]*|[@1]))", word)
        variants = [word]
        for braced, plain in variables:
            variable = braced or plain
            marker = "${" + braced + "}" if braced else "$" + plain
            loops = re.findall(r"\bfor\s+" + re.escape(variable) + r"\s+in\s+([^;\n]+)", source)
            values = []
            if loops and variable == "status":
                values = shlex.split(loops[0])
                if any("$" in value for value in values):
                    raise ValueError(f"unexpandable loop: {variable}")
            elif variable in OPERANDS:
                values = ["@operand:" + variable]
            elif wrapper and variable in ("@", "out[@]"):
                values = [marker]
            else:
                raise ValueError(f"unexpandable engine argument: {word}")
            variants = [item.replace(marker, value) for item in variants for value in values]
        choices.append(variants)
    return [list(items) for items in itertools.product(*choices)]


def wrapper_arguments(source, kind):
    ids = [[]]
    for match in re.finditer(r"(?:\$\(|^\s*)(configless_project_ids)\s+([^\n]+)", source, re.M):
        args = words(match[2])
        ids.extend(expand(args, source))
    if kind == "ids":
        return ids
    forms = []
    for match in re.finditer(r"(?:\$\(|^\s*)configless_project_ps\s+([^\n]+)", source, re.M):
        args = words(match[1])
        if "$@" in args:
            forms.extend([[*args[: args.index("$@")], *extra] for extra in ids])
        else:
            forms.append(args)
    if not forms or any("--" not in form for form in forms):
        raise ValueError("unresolved configless_project_ps caller")
    return forms


def command_options(tokens):
    options = []
    index = 0
    while index < len(tokens):
        word = tokens[index]
        if word in OPTIONS:
            if index + 1 == len(tokens):
                raise ValueError(f"option without value: {word}")
            options.extend(tokens[index : index + 2])
            index += 2
        elif word in FLAGS:
            options.append(word)
            index += 1
        elif word.startswith("-"):
            raise ValueError(f"unknown engine option: {word}")
        elif word in ("$@", "${out[@]}"):
            raise ValueError("unresolved engine wrapper")
        else:
            index += 1
    return options


def extract(directory):
    rows = []
    source = "\n".join(p.read_text() for p in sorted(Path(directory).glob("*.sh")))
    owner = ""
    for file in sorted(Path(directory).glob("*.sh")):
        text = file.read_text().replace("\\\n", " ")
        for line in text.splitlines():
            function = re.match(r"^(\w+)\(\)\s*\{", line)
            if function:
                owner = function[1]
            for match in COMMAND.finditer(line):
                verb = match[2].split()
                raw = words(line[match.end() :])
                expanded = expand(
                    raw, source, owner in ("configless_project_ps", "configless_project_ids")
                )
                for tokens in expanded:
                    if "$@" in tokens or "${out[@]}" in tokens:
                        if owner not in ("configless_project_ps", "configless_project_ids"):
                            raise ValueError(f"unresolved wrapper: {owner}")
                        for caller in wrapper_arguments(
                            source, "ps" if owner.endswith("_ps") else "ids"
                        ):
                            if owner.endswith("_ps"):
                                boundary = caller.index("--")
                                out, extra = caller[:boundary], caller[boundary + 1 :]
                            else:
                                out, extra = [], caller
                            resolved = []
                            for word in tokens:
                                resolved.extend(
                                    out
                                    if word == "${out[@]}"
                                    else extra
                                    if word == "$@"
                                    else [word]
                                )
                            rows.append({"args": [*verb, *command_options(resolved)]})
                    else:
                        rows.append({"args": [*verb, *command_options(tokens)]})
    unique = {json.dumps(row, sort_keys=True): row for row in rows}
    if not unique:
        raise ValueError("engine census extracted no command forms")
    return [unique[key] for key in sorted(unique)]


def check_shape(args, output):
    template = next((args[i + 1] for i, item in enumerate(args) if item in ("--format", "-f")), "")
    date = r"[0-9]{4}-[0-9]{2}-[0-9]{2}"
    clock = r"[0-9]{2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?"
    timestamp = (
        rf"{date}T{clock}(?:Z|[+-][0-9]{{2}}:[0-9]{{2}})"
        rf"|{date} {clock} [+-][0-9]{{4}} [A-Za-z0-9+-]+"
    )
    scalar = {
        "{{.State.Running}}": r"true|false",
        "{{.State.ExitCode}}": r"[0-9]+",
        "{{.State.Status}}": r"[a-z]+",
        "{{.State.Health.Status}}": r"healthy|unhealthy|starting",
        "{{.State.StartedAt}}": timestamp,
        "{{.Id}} {{.State.StartedAt}} {{.State.Running}}": rf"[0-9a-f]+ (?:{timestamp}) (?:true|false)",
        "{{.Image}}": r"(?:sha256:)?[0-9a-f]+",
        "{{.Config.Image}}": r"[^ ]+",
        "{{.HostConfig.RestartPolicy.Name}}": r"no|always|unless-stopped|on-failure|",
        "{{.Names}}": r"[^ ]+",
        "{{.Service}}": r"[^ ]+",
        "{{.State}} {{.ID}}": r"[a-z]+ [0-9a-f]+",
        '{{index .Config.Labels "com.docker.compose.project"}}': r"[^ ]+",
        '{{index .Config.Labels "com.docker.compose.service"}}': r"[^ ]+",
        '{{range .Mounts}}{{if eq .Destination "/var/lib/tor"}}x{{end}}{{end}}': r"x",
        '{{range .Mounts}}{{if eq .Destination "/var/lib/tor"}}{{.Source}}{{end}}{{end}}': r"/.+",
    }
    restart = "{{.Id}}\t{{.Name}}\t{{.State.Status}}\t{{.RestartCount}}\t{{.State.StartedAt}}"
    table = "{{.Names}}\\t{{.State}}\\t{{.Status}}"
    state_health = (
        "{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}"
    )
    known = set(scalar) | {restart, table, state_health, "{{json .State.Health}}", ""}
    if template not in known:
        raise ValueError(f"unclassified output template: {template}")
    if args[0] == "inspect" and not output.strip():
        raise ValueError("inspect produced no output")
    for line in output.splitlines():
        if template in scalar:
            valid = re.fullmatch(scalar[template], line)
        elif template == state_health:
            valid = re.fullmatch(r"[a-z]+ (?:healthy|unhealthy|starting|none)", line)
        elif template == restart:
            fields = line.split("\t")
            valid = (
                len(fields) == 5
                and re.fullmatch(r"[0-9a-f]+", fields[0])
                and fields[3].isdigit()
                and bool(fields[4])
            )
        elif template == table:
            valid = len(line.split("\t")) == 3
        elif template == "{{json .State.Health}}":
            valid = isinstance(json.loads(line), (dict, type(None)))
        elif any(flag in args for flag in ("-q", "-aq", "--quiet")):
            valid = re.fullmatch(r"[0-9a-f]+", line)
        else:
            valid = bool(line.strip())
        if not valid:
            raise ValueError(
                f"engine output shape does not match {template or 'ps output'}: "
                f"characters={len(line)} fields={len(line.split())}"
            )


def run_manifest(manifest, project, compose, target):
    for row in json.loads(Path(manifest).read_text()):
        args = row["args"]
        argv = []
        for item in args:
            value = item.replace(
                "label=com.docker.compose.project=pithead",
                "label=com.docker.compose.project=" + project,
            )

            def replace_operand(match):
                operand = match[1]
                return (
                    project
                    if operand in ("legacy", "project")
                    else str(Path(compose).parent)
                    if operand == "PWD"
                    else target
                    if operand in ("1", "name")
                    else "probe"
                )

            value = re.sub(r"@operand:([A-Za-z_0-9]+)", replace_operand, value)
            argv.append(value)
        if argv[:2] == ["compose", "ps"]:
            argv = ["compose", "-p", project, "-f", compose, *argv[1:]]
        elif argv[0] == "inspect":
            argv.append(target)
        result = subprocess.run(["docker", *argv], text=True, capture_output=True, timeout=20)
        if result.returncode:
            raise ValueError(f"engine form refused: {args}: exit {result.returncode}")
        check_shape(args, result.stdout)
    print("engine command forms: PASS")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    scan = sub.add_parser("extract")
    scan.add_argument("directory")
    run = sub.add_parser("run")
    for key in ("manifest", "project", "compose", "target"):
        run.add_argument(key)
    args = parser.parse_args()
    if args.mode == "extract":
        print(json.dumps(extract(args.directory), indent=2))
    else:
        run_manifest(args.manifest, args.project, args.compose, args.target)
