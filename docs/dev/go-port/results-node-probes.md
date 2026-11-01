# Remote-node probe results

Historical paired commands, results and limits from the Go port.

## Remote Monero preflight slice (2026-10-31)

`go/internal/nodeprobe/monero.go` implements the RPC probe in `10-node-probe.sh`.
It preserves IPv6 brackets, the supplied/default response cap, stdin-only digest
credentials, exact curl/timeout arguments, HTTP/body framing and failure reasons.
The JSON verdict requires `OK`, an accepted network and nonnegative numeric
heights; decimal/exponent forms, negative zero, unsafe-size integers, malformed
or multiple JSON documents, Unicode escapes and invalid JSON UTF-8 defer to Bash.
NUL output and unusual tool launches also defer rather than hide diagnostics.
Config readers, address allowlists, ZMTP and caller orchestration remain Bash;
the new package has no production caller yet.

Nine tagged groups compare 87 scenarios against the unchanged Bash function.
The first run caught a literal backslash/newline mismatch in curl's `-w` argv;
the Go argument now matches Bash exactly. Credentials and mismatch diagnostics
remain synthetic and credential-free, respectively. All probes use fake tools.
Private command and exit records use `.go-cache/logs/preflight-*`.

Commands below use `PITHEAD_IMPL=bash` (or `python` for dashboard/fakes) as the
baseline and `tests/go-parity/run.sh` for Go selection, with local caches.

| Current command | Baseline | Go selection |
|---|---|---|
| `make test-go-node-monero-parity` | PASS, 9 groups / 87 scenarios | PASS, same scenarios |
| `make test-go-doctor-monero-parity test-go-doctor-parity test-go-parity` | PASS, plus Go units | PASS, plus Go units |
| `python3 tests/stack/doctor/test-json-contract.py` and `python3 tests/stack/doctor/check-ids.py .` | PASS, 2 contract tests and pinned IDs | PASS; original source contracts |
| `make test-dashboard` | PASS, 3716 tests, 97.42% coverage | PASS, same counts; Python backend |
| `make test-fakes` | PASS, 54 tests | PASS, 54 tests; Python backend |
| `COMPARE=a73ffced33800de9435779a9cabef53864455acb make test-patch-coverage` | PASS, not applicable: no Python changes | Same result |
| `FILE_BUDGET_BASE_REF=a73ffced33800de9435779a9cabef53864455acb make lint-file-budget lint-pithead-build lint-docs-voice lint-path-references lint-operator-strings` | PASS | PASS |
| `make test` with absent Docker socket and local npm cache | FAIL, 22 third-party cache Markdown findings, exit 2 | Same result; shell/Python/JS/YAML lint pass |
| `make test-stack` | macOS refusal, exit 2 | Same refusal |

`go -C go test -count=1 ./...`,
`go -C go test -tags=parity -race -count=1 ./internal/nodeprobe`,
`go -C go vet -tags=parity ./...`,
`GOOS=linux GOARCH=amd64 go -C go build -o ../.go-cache/pithead-linux-amd64 ./cmd/pithead` and
`GOOS=linux GOARCH=amd64 go -C go test -c -o ../.go-cache/nodeprobe-linux.test ./internal/nodeprobe`
pass. Linux compilation is not a Linux runtime verdict.
Source and security reviews found no remaining implementation defect.
The adapter passes `bash -n`, ShellCheck 0.11.0 and shfmt 3.13.1.

Scoped Markdown passes in both modes with the local npm cache:

```bash
npm_config_cache="$PWD/.go-cache/npm" npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc --no-globs \
  docs/dev/go-port/PARITY.md docs/dev/repo-map.md \
  docs/dev/go-port/results-cli-probes.md docs/dev/go-port/results-network-probes.md
```

[Back to the parity ledger](PARITY.md)
