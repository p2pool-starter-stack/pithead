# AI development workflow

One set of rules, bounded tasks, and retained evidence for contributors using
Claude, Codex, or an editor assistant.

## Shared instructions

[`AI_RULES.md`](../../AI_RULES.md) is the only maintained rules file. Relative
symlinks make it available through each tool's entry point:

```text
AI_RULES.md
AGENTS.md    -> AI_RULES.md
CLAUDE.md    -> AI_RULES.md
.cursorrules -> AI_RULES.md
```

The links are committed; a normal checkout with symlink support needs no setup.
To recreate a missing link from the repository root:

```bash
ln -s AI_RULES.md AGENTS.md
ln -s AI_RULES.md CLAUDE.md
ln -s AI_RULES.md .cursorrules
```

These commands intentionally refuse to overwrite an existing file. Compare an
existing tool-specific file before replacing it. Use Linux, macOS, or WSL for the
repository's Bash tooling. On Windows, enable Git symlink support before checkout
or work inside WSL; a regular file containing only `AI_RULES.md` is not the rules.

Codex discovers `AGENTS.md` from the repository root toward its working directory.
See the [official instruction discovery documentation](https://learn.chatgpt.com/docs/agent-configuration/agents-md).
For a tool that does not follow these links, attach `AI_RULES.md` explicitly.
Do not maintain another copy of its content.

## Division of labor

These are this project's routing defaults, not claims that a provider is required
for a particular task. Use the models available in the contributor's account.

| Work | Default owner | Deliverable |
|---|---|---|
| Read a bounded file set, inventory tests, extract a log summary | Codex Luna or Claude Haiku | Findings with paths and evidence; no speculative redesign |
| Implement an agreed change, run shell commands, fix tests, group files | Codex Sol at medium effort | Small commits and actual check results |
| Appliance architecture, install/recovery experience, dashboard interaction and visual review | Claude with a reasoning model appropriate to the task | A concrete design or rendered review with affected contracts |
| Disputed evidence, cross-process ordering, or an architecture problem unresolved by the first pass | Codex Astra or a stronger Claude reasoning model, explicitly selected | A bounded decision and a check that distinguishes the alternatives |
| Review correctness, security, and acceptance | A fresh non-author session; prefer the other provider when available | PASS or RETURN at the full current SHA, with commands and limits |

Do not route routine terminal work to the largest model by default. Start with a
controller and at most two workers; keep each worker's paths disjoint. Add a
temporary reviewer when the candidate is ready. One process owns a shared build
host or test machine at a time, including cleanup.

## Appliance scope

The appliance lives in [`os/`](../../os/README.md); its battery lives in
[`tests/os/`](../../tests/os/). The runtime is built from the rootfs Dockerfile,
image scripts, overlays, and RAUC configuration in that tree. Follow the checked-in
builders; do not infer that mkosi or cloud-init is the image build entry point.

Start an appliance task with those two directories. Add a named
`lib/pithead/` slice or dashboard wizard module only when the observed flow requires
it, and record that boundary before editing. This restriction applies to appliance
tasks; it must not prevent an authorized dashboard or repository refactor.

Before execution, record the issue, base SHA, branch/worktree, owned paths, expected
checks, hardware reservation, and stopping condition. Preserve another task's
dirty tree or image candidate. Release publication remains a separate operation.

## Bounded logs

Keep complete logs for diagnosis and retain the real command status. For example,
from the repository root, with battery arguments selected for a reserved bench:

```bash
umask 077
mkdir -p os/build/logs
log="os/build/logs/battery-$(date -u +%Y%m%dT%H%M%SZ).log"
rc=0
bash tests/os/run.sh "$@" >"$log" 2>&1 || rc=$?
printf '%s\n' "$rc" >"$log.exit"
bash scripts/sanitize-test-log.sh "$log" >"$log.summary"
cat "$log.summary"
printf 'Battery command exit: %s\n' "$rc"
```

The default excerpt selects up to 120 source lines: the first 20, the first 40
matching failure markers, and the last 60. It deduplicates overlaps, strips terminal
controls, clips long lines to 240 columns, and reports omitted lines. It reads a
file or stdin and leaves the input unchanged. Selection is a diagnostic heuristic;
an omitted line can contain the cause, and a matching word can be harmless text.

Use the numbered excerpt to choose a narrow range when more context is needed:

```bash
sed -n '420,500p' "$log" | bash scripts/sanitize-test-log.sh --lines 120 --width 240
```

Do not consume raw serial logs with `cat` or an unbounded tool response. Do not
replace full evidence with an excerpt, infer PASS from a quiet summary, or publish
it without the repository's credential and topology review.

## Review and handoff

Run affected checks during implementation, then the combined required gates once
the candidate is stable. Record collected tests and assertions so moves cannot
silently remove coverage. A static review does not establish a runtime PASS.

End with owner, branch, full SHA, changed areas, tests and outcomes, retained private
evidence paths, next action, and remaining operator decisions. The next session
starts from that record and current code, not a raw transcript or provider memory.
