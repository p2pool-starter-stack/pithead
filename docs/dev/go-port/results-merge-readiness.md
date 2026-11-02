# Merge readiness, 2026-11-02

The operator's 15:15Z ruling stops new native slices. This round repairs the
existing gates and records reference-path changes. `STATUS: IN PROGRESS` remains
appropriate: Bash lifecycle operations, Python orchestration and the outstanding
platform proofs are still required.

## Unchanged dashboard gates

Both arms used `env -u PITHEAD_IMPL make test-dashboard` or
`PITHEAD_IMPL=go make test-dashboard`, respectively, with the unchanged 80%
threshold and normal test discovery. Neither arm loaded a parity plugin. The
locked Python 3.11 environment contains both test and development extras. Each
arm used a fresh coverage dataset, one xdist worker and GNU utilities first on
PATH. Coverage precision changes presentation only.

| Selection | Tests | Statement coverage | Missing / statements | Patch coverage |
|---|---|---|---|---|
| `PITHEAD_IMPL` unset | 4102 passed | 95.56% | 579 / 13044 | 91%, 339 / 4092 changed lines missing |
| `PITHEAD_IMPL=go` | 4102 passed | 92.60% | 965 / 13044 | 92%, 318 / 4092 changed lines missing |

Each arm immediately ran the unchanged `make test-patch-coverage`, using the
normal `origin/develop` comparison and 90% threshold. The local base is
`2b8a778fcafa12db40991de95a8563bd5867ca0b`; CI fetches its current PR base
before running the same target. All 76 changed measured files appear in each
coverage XML. Every measured application
module is tracked. These results do not combine the two coverage datasets and
do not depend on an untracked application adapter. No coverage source, omission,
threshold, existing test or fixture changed.

A further reference arm points both Go binary overrides at missing files:
all 4102 tests and the default patch gate pass again at 95.56% / 91%. The new
tests therefore do not require a built Go binary in the Python-only CI job.
Its separate records are `go-merge-reference-no-go{,-patch}.{log,json}`.

The ordinary suite now includes 383 new bridge contract cases in
`dashboard/tests/bridges/`, alongside 3719 existing tests. The frozen starting
suite contained 3716 tests; three supplementary tests predate this round. The new
cases exercise transport envelopes, provider capture, installation, malformed
responses, exceptions, cleanup and reference fallback in both selections. They
measure Python bridge coverage; native ownership still needs the separately
recorded focused fatal-source, body and mutation oracles.

Full output and separate exit/time records are private in
`.go-cache/logs/go-merge-final-{reference,native}.{log,json}` and the corresponding
`-patch` records. Coverage datasets remain separate under
`.go-cache/coverage-merge-final-{reference,native}/`.

## Reference compatibility repair

The ordinary Go dashboard run exposed eight failures in unchanged wizard restore
tests. Native transaction I/O had bypassed their interposed `os.replace` and
`os.unlink` providers. `go_wizard_transaction.py` now invokes its captured Python
operations only while either provider is interposed. Normal I/O remains native.
Already-built conflict responses pass through unchanged. This preserves injected
failures and their diagnostics without changing the normal selection contract.

All 26 original restore limit/security cases pass with Go selection. The focused
transaction target passes 295 cases and records native operations separately
from explicit I/O interpositions. An independent security review found no
critical, high or medium issue in this repair.

## Additive parity setup

The new `dashboard/conftest.py` activates only for Go parity runs that load the
existing channel plugin, including nested mutation oracles. For typed wizard
requests, a dict subclass lets an older operation counter read
the existing `phase` value without adding an `operation` field to the JSON wire.
The transaction target proves this adapter with native call/error counters. The
unchanged recovery source-mutation guard also passes: its nested original suite
now reaches the intended bad-config assertion instead of failing in the counter.

The new `tests/go-parity/conftest.py` isolates the minimal Python child-startup
fixture, which contains only its own `main.py` and
shell template. Its isolated startup disables the dashboard editable-install
finder so missing fixture modules cannot resolve into production subpackages.
Installed dependencies remain available. Real dashboard child startup retains
its normal import and native storage/control installation paths.

## Lint repairs

Markdown lint now ignores only `.go-cache/` and `.uv-cache/`, alongside its
existing dependency-cache exclusions. Project Markdown rules remain unchanged.
A malformed Markdown control inside `.go-cache/` passes; the same malformed
project-root control fails with MD022. Both temporary probes were removed.

The firstboot wizard exceeded the current `origin/develop` file budget. Removing
36 explanatory comment lines brings it to 473 lines under the existing ceiling
of 476. Its parsed Bash function is byte-identical before and after. The
`provision-browser-submit.sh` budget now records its actual 406 lines; that test
file is unchanged. The default file-budget comparison passes without an override.

## Workflow gates

`make lint` passes with GNU grep/coreutils/sed first on PATH and the default
file-budget base. A separate final documentation pass checks Markdown, prose
style and path references. Go 1.27.1 command builds, race units, vet and all eight
CLI parity targets and all 40 dashboard workflow targets pass in the disposable
Linux ARM64 runner. Build/race/vet take 55 seconds, CLI targets 390 seconds and
dashboard targets 467 seconds: 928 seconds total, within the existing 25-minute
job limit. These are local executions of the workflow commands, not a published
GitHub Actions status or AMD64 execution proof.

The source snapshot is SHA256
`d2ca3e1dd3691fd96712c25ee20231ac2c999fe4fffe159df968a4d4c0232b04`.
Before dashboard collection, the two new configurations were refreshed:
`dashboard/conftest.py` SHA256
`07de00ded37d9806680b3708ad88d9e3e31e12ea86ec9c3c44941e2176e0bfbf`
and `tests/go-parity/conftest.py` SHA256
`4227b7f8ad75238b8e909c14b15037a66508b60be63497ccc797745073aeef99`.
The host source mount stayed read-only; all builds and caches were disposable.
Private full log: `.go-cache/logs/go-ci-full-linux-arm64.log`, SHA256
`f0e637b5e57576048c729b6c0d75a3c5609ca6bd0c2b9c6af7779176963f5953`,
with a separate exit-zero metadata record. Both Linux command sets skip two
keep-running mutation controls because `PITHEAD_SCOPE_UNSUPPORTED_BINARY` and
`PITHEAD_SCOPE_EMPTY_BINARY` are unset. Their ordinary full-oracle/fragment guard
runs and passes; separately supplied mutant controls remain in the prior
keep-running report. These skips are not native ownership proof.

Ordinary `make test` was also attempted in both selections. Both pass lint,
all 4102 dashboard tests and frontend tests, then stop at the unchanged explicit
macOS refusal in `test-stack`. The fresh ordinary Go dataset still has 965
missing statements of 13044 (92.60%); its immediate default patch gate passes
at 92%. The refusal was not bypassed; this is not a full-suite pass. Separate
exit records are in `go-merge-test-{reference,native}.json` and
`go-merge-test-native-patch.json` in the private log directory.

## Status escape bytes (G7)

G7 started only after the preceding merge gates passed. Go now writes Bash's raw
Unicode-escape bytes, including surrogate values and legacy five/six-byte UTF-8
sequences through `0x7fffffff`; values at or above `0x80000000` emit no bytes.
C/POSIX locales retain non-ASCII Unicode escapes literally. Parsing, ordinary
escapes, truncation and status write-error handling are unchanged.

Native bare status accepts C/POSIX directly and otherwise requires a successful,
quiet `locale charmap` result identifying UTF-8. Other character sets and failed
providers use Bash. The launcher preflights noncanonical bare-status locales:
invalid/ASCII-fallback diagnostics keep execution in the original Bash process,
so an invalid locale does not cause a second startup warning. Reference selection
is unaffected. Unsupported locale paths are compatibility evidence, not native
formatter proof.

The existing nine-case supplementary status comparison (unchanged this round)
and four new full-CLI comparisons pass
locally. New Go units cover byte boundaries, partial/invalid escape digits,
C literals, locale precedence, character-map aliases, provider stderr and provider
failures. The new comparisons check all three process results, forbid fallback
for verified UTF-8 and require it for an installed non-UTF-8 locale. Invalid-locale
cases forbid invoking the native binary and compare the complete stderr bytes.
The available Latin-1 compatibility case passes locally; a platform without that
locale reports an explicit supplementary-test skip.

Independent verification passes the encoder, eligibility, selector and stream
boundaries. Final Linux ARM64 Go 1.27.1 builds, affected status/CLI race tests
and vet, and the exact eight CLI targets pass in 201 seconds. The new script
reports three passes and one explicit non-UTF-8-locale skip on Linux; all four
pass locally. The preceding forty-target dashboard proof covers unchanged
dashboard code. These added comparisons do not replace or prove the full
original Linux stack/status matrix.

Final G7 snapshot SHA256:
`174d0a6b78574f35ec8765756a078f4c2c72dc641c1d64006e4239cbd155035b`.
Private log `.go-cache/logs/g7-linux-arm64-final.log`, SHA256
`23b7a6a035b16b9733b2e0c8e34c7dc9a6f84271f9e9662c0f0306ca342edec9`.
Metadata is `.go-cache/logs/g7-linux-arm64.meta`, SHA256
`baf92ccfc035be9d6943612398ce270e3545cac96e563f895b801ae62ee41fcc`,
whose final fields record exit zero and 201 seconds. Earlier unsuitable bind-mount
and missing-Git-metadata attempts remain separate from the final proof. No doctor
implementation changed.

The frozen original status-related oracles include
`tests/stack/test-status-sync-hold.sh`, `tests/stack/test-cli.sh` and
`tests/integration/selftest/selftest-readiness-status.sh`. The first two remain
behind the full Linux stack limitation; ordinary sourced stack helpers scrub Go
selection. The readiness selftest checks parsing/vocabulary, not native rendering.
None is relabeled as one of the new synthetic comparisons.

## Limits

These local Python coverage results and GNU-first checks do not establish full
Linux stack, privileged lifecycle, appliance, AMD64 execution, fleet or published
artifact parity. Existing scoped Linux ARM64 evidence remains in the prior
results. No live host changed and no performance improvement is claimed.

## Preserved firstboot rationale

The comment-only budget repair preserves these existing invariants for review:

- Staged rig answers move from the installed ESP to `/data`; the installation
  medium remains installer-owned. Refused staged credentials are still scrubbed.
- An accepted rig role starts mining best-effort, including run-from-USB rigs.
  The explicit setup-again entry bypasses that shortcut.
- Preseeded configuration never authorizes erasing the installation medium.
  A carried restore precedes config consumption even when a prior config exists;
  failure to clear temporary restore secrets stops boot.
- Consumed plaintext config is removed from an installed machine's ESP. A
  removable fleet stick remains the operator's reusable medium.
- `STACK_VERSION` derives the published image tag. Offline first boot uses the
  existing baked-image loader even before networking is configured.
- The removable-media warning remains visible. Cleanup traps expand local engine
  and spool values when installed, so they can clear secrets after locals expire
  without masking the original failure under `set -u`.

The existing shellcheck expansion pragma remains; no executable line, lock,
cleanup order, diagnostic or trap expansion changed.
