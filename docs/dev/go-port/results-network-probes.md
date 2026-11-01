# Network and firewall parity results (2026-10-31)

Detailed results linked from the [parity ledger](PARITY.md). Shared guard commands
are in the [control slice](results-cli-probes.md#control-unit-and-local-miner-slice-2026-10-31).

## Network diagnostics slice (2026-10-31)

`host.PublicIP` and `PublicIPs` retain the legacy IPv4 exclusions, lexical
leading-zero behavior, permissive IPv6 first-hextet gate, interface order,
duplicates and unterminated-record handling. Native doctor packages port effective
stratum settings, exposure findings/setup warnings, container-state queries,
Tor-running findings, listener checks and the bounded Tor clearnet probe. They
retain getter gates, exact tool arguments, partial output on nonzero status,
short-circuit order and listener pipeline failures. Doctor exposure messages
withhold public IP and password values; setup warnings retain public IP values.
The production collector and dotenv parsing remain Bash.

Unsupported launches, NUL/overflow inputs, tool diagnostics and unusual narrowed
binds decline a native verdict. Narrowed exposure also falls back when grep is
missing, bind text looks like an option, or public output exceeds 512 bytes;
this preserves the original grep-option and printf/grep pipefail behavior.
Setup warning escapes also fall back.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Network probes | `PITHEAD_IMPL=bash make test-go-doctor-network-parity`: PASS, 16 tagged comparison groups and Go units | `tests/go-parity/run.sh make test-go-doctor-network-parity`: PASS |
| CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-network-parity test-go-doctor-parity test-go-parity`: PASS, 15 initial network groups plus 13 JSON and 12 CLI groups | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS on retry, same count/coverage; backend remains Python |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: same result, including after the retry |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run
'TestNetwork|TestStratumExposure|TestPublicIP' ./internal/doctor ./internal/host`,
`go -C go test -count=1 ./...`, `go -C go vet -tags=parity ./...` and the Linux
build command above pass. The final TLS-tool comparison also runs under race
checking with `go -C go test -tags=parity -race -count=1 -run
TestNetworkTLSNormalizationTools ./internal/doctor`: PASS. Linux compilation
provides no runtime verdict. Adapter syntax, pinned ShellCheck/shfmt pass;
Go formatting and scoped Markdown checks pass. Independent static review
passes with no remaining defects.

The first Go dashboard run had 3715 passes and one failure in
`TestBoundedRead.test_a_trickled_body_does_not_cost_quadratic_time` (5.66 seconds
against its unchanged four-second limit); the same full suite passed on retry.
Early new-harness compile, ShellCheck and diagnostic-stream assertions were
corrected before paired runs; one fixture process also reported a syntax error
during an adapter edit. Stable reruns pass. Existing tests, fixtures, goldens,
lint rules and Make checks remain unchanged. Private command/exit records use
`.go-cache/logs/network-*`. No Git write, download, real interface/listener probe,
external network request, live container or daemon contact occurred.

## LAN guard diagnostics slice (2026-10-31)

`go/internal/firewall/` implements read-only LAN rule verification for iptables
and nft, preserving return codes 0–5, terminal DROP checks, tagged jump coverage,
foreign ACCEPT/RETURN precedence and FORWARD reachability. The nft path retains
the legacy requirement that one forward-hooked drop rule mentions every port;
it retains the original acceptance of an earlier ACCEPT expression. It validates
all relevant expressions before returning success. Unsafe JSON precision,
fractional/extreme numbers, Unicode line separators, non-string rule chains,
unsupported shapes, noncanonical ports, NUL output, relative tool paths and
unusual executable formats decline a native verdict for future Bash fallback.

The doctor packages implement published-bind enumeration, readback reasons,
boot-unit applicability, restart-policy/exit-code hold reports and the combined
LAN report. They preserve container deduplication in hold checks, repeated
container/exit queries elsewhere, suppressed streams and the Docker-port/grep
pipeline's producer failure and SIGPIPE behavior. The production collector,
dotenv readers, firewall mutations, markers and recovery remain Bash.
The native path retains the source's permissive token/substring matching and
failed Docker-read classifications.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| LAN probes, doctor JSON and CLI | `PITHEAD_IMPL=bash make test-go-doctor-lan-parity test-go-doctor-parity test-go-parity`: PASS, 20 LAN groups plus 13 JSON and 12 CLI groups, and Go units | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS, same count/coverage; Python backend |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: PASS, not applicable |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI/firewall suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run TestLAN ./internal/doctor`,
`go -C go test -race -count=1 ./internal/firewall`,
`go -C go test -count=1 ./...`, `go -C go vet -tags=parity ./...` and
`GOOS=linux GOARCH=amd64 go -C go build -o
../.go-cache/pithead-linux-amd64 ./cmd/pithead` pass. The visible-systemctl-output
fallback witness also passes under race checking with
`go -C go test -tags=parity -race -count=1 -run TestLANHoldFallbacks
./internal/doctor`. Adapter syntax, pinned ShellCheck/shfmt, Go formatting and
scoped Markdown checks pass. Independent static and security review pass with
no remaining new defects.

An early `GOOS=linux GOARCH=amd64 go -C go test -run '^$'
./internal/firewall` failed when macOS could not execute the Linux test binary.
The corrected `GOOS=linux GOARCH=amd64 go -C go test -c -o
../.go-cache/firewall-linux-amd64.test ./internal/firewall` passes. These Linux
compilations provide no Linux runtime verdict.

Early comparisons corrected the new adapter's conditional calling context,
reason-output newline expectation, reached-tool fixture and formatting. A new
fractional-number witness initially expected the wrong Bash result; the recorded
oracle result is now asserted. Review found and corrected Unicode serialization
and array-valued rule-chain verdict differences through explicit fallback.
No existing test changed. Private command/exit
records use `.go-cache/logs/firewall-*`. No shared Git metadata write, external network request,
live firewall, container, systemd or daemon probe occurred.

## Docker Tor egress diagnostics slice (2026-10-31)

This slice starts at `e17928548b1b9ddadba3cfbcbf997a85b983344a`.

Native firewall helpers preserve the libxtables quoted-token format, partial
token output on malformed quotes, CIDR overlap/containment, source negation,
foreign-rule shadowing, sync-ACCEPT validation and canonical option ordering.
The Docker readback preserves return codes 0–5, rule order, exemption counts,
late/conditional/duplicate exemption rejection, tagged-rule membership and the
canonical FORWARD jump with preceding-rule checks. Exact state/config getter
outputs are supplied; their collection, marker interpretation, transitions and
all mutations remain Bash. Podman/nft readback declines a native verdict for
fallback. Doctor reports retain the toggle/Tor gates, backend/surface wording,
boot-unit warning and command arguments.

NUL, quoted newlines, unquoted non-ASCII text, unsafe arithmetic, octal prefixes in containment/overlap,
ambiguous trailing-dot arithmetic, unsupported executable formats and missing
text tools decline a native verdict. Decimal leading-zero validation and the
source's permissive tagged-rule membership behavior are preserved.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| Tor egress probes | `PITHEAD_IMPL=bash make test-go-doctor-egress-parity`: PASS, 18 tagged groups and Go units, including after the locale fallback fix | `tests/go-parity/run.sh make test-go-doctor-egress-parity`: PASS |
| CLI and doctor JSON | `PITHEAD_IMPL=bash make test-go-doctor-egress-parity test-go-doctor-parity test-go-parity`: PASS, 18 egress, 13 JSON and 12 CLI groups, plus Go units | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS, same count/coverage; Python backend |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: PASS, not applicable |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI/firewall suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run TestEgress
./internal/firewall ./internal/doctor`, `go -C go test -count=1 ./...`,
`go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build
-o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` pass. Cross-compilation
provides no Linux runtime verdict. Adapter and scoped Markdown checks pass.
Independent static review passes with no remaining defects. A local Bash oracle
confirmed the U+2003 duplicate-source witness returns rc 1 in `C` and rc 0 in
`en_US.UTF-8`. The native parser now declines that locale-dependent input;
`go -C go test -race -count=1 -run TestEgressUnquotedUnicodeFallback
./internal/firewall` passes and also checks quoted Unicode preservation.

Initial new-test runs corrected the canonical empty-input case and a reordered
fixture whose leading jump did not satisfy the source's literal-space check.
A no-shebang fixture initially attempted to overwrite a tool symlink; the sandbox
blocked it, and the fixture now unlinks the symlink before creating its fake.
No external file changed. Private command/exit records use
`.go-cache/logs/egress-*`. Existing tests, fixtures, goldens, lint rules and Make
checks remain unchanged. No shared Git metadata write, dependency download,
external network request, live firewall, container, systemd, bench or daemon
probe occurred.

## nft Tor egress and sync-state slice (2026-10-31)

This slice starts at `7a43aa3046ab9545ac0db5229831c34f0a68a3d4`.

The native nft verifier checks hooked-chain drop reachability, preceding
unconditional accepts, rule structure, the exact subnet drop, safe accept forms
and active exception counts/order. It preserves the IPv6 clause's subset-field
comparisons and the original probe order. The public API retains Bash fallback
when nft is absent, as pinned by existing Go tests. Unsupported JSON shapes,
duplicate keys, unsafe numbers, tool launches and diagnostics also decline a
native verdict. The original Bash policy remains the parity oracle.

`TorSyncState.IPs` preserves getter gates, exact booleans, raw close-chain values,
output order, newline stripping and marker checks, including directories and
dangling symlinks. Config/state-dir getter values are supplied. Collection of
those values, caller wiring, transitions and mutations remain Bash.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| nft and sync-state probes | `PITHEAD_IMPL=bash make test-go-doctor-nft-parity`: PASS, 7 nft groups, 11 sync-state scenarios and Go units | `tests/go-parity/run.sh make test-go-doctor-nft-parity`: PASS |
| Existing egress/LAN, JSON and CLI comparisons | `PITHEAD_IMPL=bash make test-go-doctor-nft-parity test-go-doctor-egress-parity test-go-doctor-lan-parity test-go-doctor-parity test-go-parity`: PASS, plus 18 egress, 20 LAN, 13 JSON and 12 CLI groups | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS, same count/coverage; Python backend |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: PASS, not applicable |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI/firewall suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run 'TestNFTEgress|TestTorSync'
./internal/firewall ./internal/doctor`, `go -C go test -count=1 ./...`,
`go -C go vet -tags=parity ./...` and `GOOS=linux GOARCH=amd64 go -C go build
-o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` pass. Cross-compilation
provides no Linux runtime verdict.
The new adapter passes `bash -n tests/go-parity/tor_sync_reference.sh`,
`shellcheck --severity=warning tests/go-parity/tor_sync_reference.sh` and
`shfmt -i 4 -d tests/go-parity/tor_sync_reference.sh`, using the pinned versions.
Independent static and security reviews pass with no remaining findings.
Changed Markdown passes in both modes with `npm_config_cache="$PWD/.go-cache/npm"
PITHEAD_IMPL=bash npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs docs/dev/go-port/PARITY.md
docs/dev/repo-map.md` and the same command through `tests/go-parity/run.sh`.

Early source comparison corrected the IPv6 matcher to retain the same extra
fields Bash ignores. Initial scoped lint attempts omitted the local npm cache
and stopped offline with ENOTCACHED; the corrected commands pass. Private
command/exit records use `.go-cache/logs/nft-*`.
Existing tests, fixtures, goldens, lint rules and Make checks remain unchanged.
No Git metadata write, dependency download, external network request, live
firewall, container, systemd, bench or daemon probe occurred.

## Tor history diagnostics and outage evidence slice (2026-10-31)

This slice starts at `525a359bd5bbfbb033d4fb68c7a506160980158c`.

Native probes preserve the root/sudo gate, regular-file and symlink checks,
ordered exact-line greps, two-target curl short-circuit and both doctor messages.
Any successful HTTP response proves egress; the source's quiet final-grep error
behavior is retained. Exposed id/sudo/grep output or curl stdout declines to Bash;
the originally suppressed sudo/curl stderr stays suppressed. Isolation credentials
retain the per-request PID/random shape; new parity tests validate that shape before normalizing its nondeterministic bytes.
Mount and config values are supplied; discovery and collector wiring remain Bash.

`torhistory.Next` preserves compact record bytes/key order, duplicate/delayed
observations, tombstones, new outages and 900-second rolling rounds. `Valid`
checks the same evidence windows. The parser supports canonical five-field
records or `{}`, with one optional LF and safe decimal integers. Reordered,
escaped, duplicate, extra, fractional, exponent, unsafe or unexpected input
falls back. Locking, persistence, schemas, audits and recovery mutations stay Bash.

| Suite | Baseline command and result | Go command and result |
|---|---|---|
| History probes and outage evidence | `PITHEAD_IMPL=bash make test-go-doctor-history-parity`: PASS, 8 tagged groups/62 scenarios plus Go units, including after the diagnostic fallback fix | `tests/go-parity/run.sh make test-go-doctor-history-parity`: PASS |
| Existing nft/egress/network, JSON and CLI comparisons | `PITHEAD_IMPL=bash make test-go-doctor-history-parity test-go-doctor-nft-parity test-go-doctor-egress-parity test-go-doctor-network-parity test-go-doctor-parity test-go-parity`: PASS | Same targets through `tests/go-parity/run.sh`: PASS |
| Existing doctor contract/catalog | Baseline Python commands in consolidated results: PASS, 2 tests and catalog | Same commands through `tests/go-parity/run.sh`: PASS; still sources Bash |
| Dashboard | `PITHEAD_IMPL=python make test-dashboard`: PASS, 3716 tests/97.42% | `tests/go-parity/run.sh make test-dashboard`: PASS, same count/coverage; Python backend |
| Fake daemons | `PITHEAD_IMPL=python make test-fakes`: PASS, 54 tests | `tests/go-parity/run.sh make test-fakes`: PASS, 54 tests |
| Patch coverage | Baseline command and compare base recorded above: PASS, not applicable; no Python changes | Same Go command/base: PASS, not applicable |
| File budget, build, docs voice, paths and operator strings | Baseline commands/base in the control slice: PASS | Same Go commands/base: PASS |
| Full gate | `PITHEAD_IMPL=bash make test`: shell/Python/JS/YAML lint PASS, then 22 cached Markdown findings; exit 2 | `tests/go-parity/run.sh make test`: same result; no Docker target reached |
| Existing CLI/firewall suite | `PITHEAD_IMPL=bash make test-stack`: unavailable, macOS refusal; exit 2 | `tests/go-parity/run.sh make test-stack`: same result |

`go -C go test -tags=parity -race -count=1 -run
'TestTorHistory|TestTorCircuit|TestTorRecovery|TestTorState|TestNext|TestValid'
./internal/doctor ./internal/torhistory`, `go -C go test -count=1 ./...` and
`go -C go vet -tags=parity ./...` pass. The CLI Linux build command above and
`GOOS=linux GOARCH=amd64 go -C go test -c -o
../.go-cache/torhistory-linux-amd64.test ./internal/torhistory` pass; no Linux
runtime verdict is claimed. The adapter passes `bash -n`, pinned ShellCheck and
shfmt. Scoped Markdown passes in both modes with the command recorded above.
Independent static and security reviews pass after the diagnostic fallback fix.

Early adapter runs corrected a missing fake-PATH `cat`, a new fixture name
collision and repeated command labels in the new trace. No existing test,
fixture, golden, lint rule or Make check changed. Private command/exit records
use `.go-cache/logs/history-*`. No Git metadata write, dependency download,
external network request, live firewall, container, systemd, bench or daemon
probe occurred.

[Back to the parity ledger](PARITY.md)
