# Go port parity adapters

Only new files under `tests/go-parity/` adapt unchanged suites or supply parity
oracles:

- `config_persistence_reference.sh` sources the original credential and CLI appliance-default writers
  with controlled providers and file operations; `test_config_persistence.py` compares JSON/file bytes,
  modes, failures, strict helper framing and the unchanged config-read extractor.
  `test_config_persistence_aliases.py` compares hardlink/symlink targets with the original writer.
  `config_write_aliases_reference.sh` and `test_config_write_aliases.py` cover that boundary for
  the existing version, worker and Telegram writers without changing their suites.
  Full first-boot and secret-file oracle suites need Linux.

- `config_migrations_reference.sh` sources the original worker/XvB and Telegram migration functions
  with controlled file failures; `test_config_migrations.py` compares decisions, exact file/backup bytes,
  permissions, callback order and the unchanged config-read extractor.
  `test_config_migrations_protocol.py` checks helper framing. The original migration suites need Linux.

- `config_version_reference.sh` sources the original version functions with controlled file operations;
  `test_config_version.py` compares policy, file bytes, metadata, cleanup and failure paths.
  The original version suite needs Linux; unchanged render fixtures run through the existing adapters.

- `config_access_reference.sh` extracts the original SSH and node-credential blocks, with
  synthetic discovery and generation/persistence callbacks; `test_config_access.py` checks
  verdicts, partial state, order and fallback without logging plaintext credentials.
  `test_config_access_render.py` compares unchanged complete-render fixtures. The original proxy
  adapter ends at the username read, which remains in Bash to preserve that boundary unchanged.

- `env.sh` restores Go selection and the binary path after the unchanged shell
  harness clears `PITHEAD_*`; `run.sh` invokes an unchanged command with that hook.
- `test_cli.py` compares generated entrypoints in synthetic installs, including
  aliases, chains, fd 9, signals, SIGPIPE and proof that native help/version do
  not execute Bash.
- `test_status.py` and `status_fixture.py` provide synthetic engine, curl and
  OpenSSL behavior without contacting a daemon or dashboard.
- `test_doctor.py` and `doctor_fixture.sh` replace only probe collection in a
  temporary generated CLI, retaining its dispatcher and Bash JSON oracle.
- `doctor_memory_reference.sh` extracts guarded free-RAM and clock verdict blocks
  and substitutes controlled meminfo because existing tests source Bash.
- `doctor_verification_reference.sh` invokes the unchanged release-verification
  function and extracts the guarded daemon verdict block. New tagged tests use
  disposable installs and fake engines because the existing doctor suite sources
  Bash functions. They compare exact TSV/human bytes and engine calls, without a
  daemon, network, image pull or verification container.
- `doctor_control_reference.sh` invokes unchanged control-unit and local-miner
  functions with supplied getter outputs, synthetic unit files and isolated tools.
  The original tests source Bash functions; this adapter reaches native packages
  without changing those tests or executing systemctl. Environment/config parsing
  remains in Bash.
- `doctor_host_reference.sh` extracts guarded dependency, boot and CPU verdict
  blocks. It uses controlled CPU files and isolated fake host tools because the
  existing source tests cannot reach Go packages. No real engine, systemd, sysctl,
  network or host probe runs.
- `doctor_disk_reference.sh` invokes unchanged disk-budget, mount-resolution and
  grouped-check functions against fake df responses. Existing tests source Bash;
  this adapter compares native findings and df calls without host disk probes.
- `doctor_data_directories_reference.sh` invokes the unchanged missing-directory
  functions and extracts guarded doctor/deployment verdict blocks. Getter outputs
  and disposable filesystem fixtures reach native packages without changing the
  source-based tests; dotenv parsing remains in Bash.
- `doctor_onion_reference.sh` extracts the guarded address-report block and calls
  the original address helpers. Getter outputs and program names reach native
  probes without changing source tests or contacting Tor; a guard prevents the
  supplied program name from turning source loading into a CLI launch.
- `doctor_config_reference.sh` extracts the guarded config-diagnostics block and
  calls the unchanged payout-address classifiers. Supplied jq/variant outputs,
  public vectors and isolated Python availability reach native packages without
  changing source tests. JSON parsing and variant-file reading remain Bash.
- `doctor_network_reference.sh` calls unchanged IP, stratum and Tor checks with
  supplied getter outputs and isolated tools. It compares native findings,
  setup warnings and command arguments without changing source tests or using
  real interfaces, listeners, containers or network requests.
- `doctor_lan_reference.sh` calls unchanged LAN readback, boot applicability,
  publishing and report functions with supplied bind getters and isolated tools.
  Existing tests source Bash; this adapter compares native verdicts, exact report
  bytes and command arguments without invoking a host firewall, engine or systemd.
  Report calls retain the dispatcher's conditional context for Bash `errexit`.
- `doctor_egress_reference.sh` calls unchanged Tor token/CIDR helpers, rules,
  readback and doctor reports. Config getters and active sync IPs are supplied
  because the source-based suites cannot reach Go packages. Its formatter-only
  operation substitutes a readback status to compare both backend/surface message
  mappings; separate readback tests use the unchanged Bash verifier and fake tools.
- `tor_sync_reference.sh` invokes the unchanged sync-IP selector with supplied
  config/state-dir getters and disposable markers. Existing suites source Bash;
  this adapter compares native selection without changing those suites or reading
  live stack state.

- `tor_history_reference.sh` calls the original history/control predicates with
  supplied time/config/mount values and fake tools. Its lock/result/audit hooks
  isolate the pure outage transition and preserve record bytes without touching
  stack state; the existing source-based tests cannot invoke native packages.

- `doctor_containers_reference.sh` calls unchanged restart and revenue checks
  using fake engines/sleep and a supplied migration hold. Source-based suites
  cannot invoke native packages; this compares findings and exact tool arguments.

- `doctor_monero_reference.sh` calls unchanged sync/peer/tip functions with
  supplied RPC getters/time, synthetic credentials and fake engines/curl. Existing
  source-based tests cannot invoke Go packages; this compares exact findings,
  authentication arguments and call order without an RPC server or container.

- `node_monero_reference.sh` extracts unchanged `monero_rpc_speaks` with a synthetic
  config and fake timeout/curl so the CLI's readonly cap does not override fixtures.
  Source-based suites cannot invoke native packages; it compares reason/exit
  status, command arguments and stdin credential bytes.

- `node_zmq_reference.sh` extracts unchanged greeting/READY/endpoint functions.
  Source-based suites cannot invoke Go packages; a fake timeout supplies reply
  bytes/status without running the endpoint's TCP shell command. It compares
  predicate and reason bytes, retaining exposed arithmetic/NUL diagnostics.

- `node_zmq_exchange_reference.sh` runs the unchanged endpoint function with its
  sole TCP opener replaced by a guarded inherited-descriptor check. Local socket
  pairs exercise actual Bash reads/writes and the five-second timeout without a
  network connection; source-based suites cannot invoke the Go exchange.

- `config_document_reference.sh` calls the unchanged embedded Python parser in
  Bash mode; `test_config_document.py` proves native selection through CLI fallback.
  The unchanged parser suite also reaches Go.

- `config_defaults_reference.sh` supplies platform/table/config fixtures to the
  Bash helpers. `test_config_defaults.py` proves native wiring and invokes the
  unchanged render fixture; existing shell suites remain guarded on macOS.

- `config_validation_reference.sh` supplies disposable config documents to the
  original validators. `test_config_validation.py` compares exact diagnostics and
  statuses, proves native selection without jq and checks compatibility fallback.
  Existing source-based suites and their fixtures remain unchanged.

- `stratum_reference.sh` sources the original parser and error function, recording
  globals on exit. `test_stratum.py` compares exact outputs, status and partial
  state, proves native selection without jq and checks fallback beyond the
  standalone preflight cases. Full config cases still require the Linux stack harness.

- `site_names_reference.sh` supplies synthetic discovery to the original site/SAN functions;
  `test_site_names.py` compares names, SANs and fallback. `site_names_caddy_reference.sh` loads the
  unchanged Caddy fixture around production site functions; `test_site_names_render.py` compares complete files.
- `wallet_settings_reference.sh` extracts the original wallet gate/classifier cases; new wallet tests
  compare native/fallback state and unchanged complete-render fixtures.
- `payout_settings_reference.sh` extracts the original payout-setting blocks and records
  partial state and date/key-check callbacks; `test_payout_settings.py` checks native/fallback behavior and
  `test_payout_settings_render.py` compares unchanged complete render fixtures.
- `caddy_bind_reference.sh` loads the new bind hook before the unchanged Caddy adapter;
  `test_caddy_bind.py` runs the existing Caddy tests and adds bind/fallback comparisons.
- `directories_reference.sh` extracts directory derivation plus the original safety loop,
  recording globals and guard/trap calls. `test_directories.py` checks native plans/fallback;
  `test_directories_render.py` adds layouts and rejections through the unchanged render fixture.
- `dashboard_auth_reference.sh` extracts the original auth/policy blocks, supplying
  synthetic hash/previous-env results. `test_dashboard_auth.py` compares credentials,
  verdicts and operation order without logging plaintext; Linux auth tests remain unchanged.
  `test_dashboard_auth_render.py` pre-seeds cached hashes for unchanged-fixture renders; a Docker stub prevents daemon use.

- `dashboard_access_reference.sh` extracts the original access-settings block and
  records globals, discovery calls and inherited traps. `test_dashboard_access.py`
  compares native/fallback behavior because invalid-config tests require Linux.
  `test_dashboard_access_render.py` reuses the unchanged render fixture for additional access-setting cases.

- `proxy_settings_reference.sh` extracts the original proxy-settings block and
  records globals and auto-password calls. `test_proxy_settings.py` compares
  native parsing/validation and fallback without changing the Linux oracle.

- `network_settings_reference.sh` extracts the unchanged network/remotes/pool block
  and records globals on exit. `test_network_settings.py` compares verdict bytes,
  partial state, mode changes, native jq avoidance and helper fallback because
  full invalid-config cases require the Linux stack harness.

- `caddy_reference.sh` loads both Caddy slices and supplies synthetic addresses,
  certificate files and mint outcomes to the production renderer. `test_caddy.py` compares complete files,
  logs, statuses and preparation calls, including partial-file failures. A binary
  shim proves native sections succeed without recording their secret inputs.
  Docker-backed Caddy parsing remains an unavailable separate contract check.
  `caddy_auth_reference.sh` sources the new auth hook before the unchanged adapter;
  `test_caddy_auth.py` checks auth/digest preparation and fallback.
  `caddy_sites_reference.sh` reuses that unchanged adapter with controlled IFS and
  working-directory fixtures; `test_caddy_sites.py` adds host/port/protocol cases
  because the original adapter cannot vary IFS before sourcing the renderer.

- `env_render_reference.sh` invokes the original dotenv formatter for supplied
  values. `test_env_render.py` calls the unchanged render fixture with additional
  config cases, compares `.env` and secret-file bytes/modes and requires exactly
  one successful native batch. `test_env_getters.py` adds partial-output/failing
  getter and inherited-ERR-trap coverage using the same unchanged fixture for
  setup. These added cases supplement the unchanged suites.

- `test_env_network.py` invokes the same unchanged render fixture with network
  configuration cases and a helper-status shim. It checks complete output/files
  and proves the network plan succeeds natively or takes compatibility fallback.
  `env_network_reference.sh` sources that unchanged fixture, then stubs CPU count
  for a second render because the original fixture fixes it at eight. Malformed
  private frames and poisoned success/trailing-data cases are supplementary checks.

- `test_env_dashboard.py` compares the unchanged render fixture with dashboard,
  worker and alert settings, proving native selection and compatibility fallback.
  `env_dashboard_reference.sh` only supplies the canonical Bash defaults table
  for private-protocol cases; it does not replace a reference suite.

- `test_env_memory.py` compares complete renders and helper failure cases.
  `env_memory_reference.sh` sources the unchanged render fixture, then supplies
  deterministic RAM/HugePages for a second render and records hardware-read
  order. The original fixture has fixed explicit limits and cannot vary auto sizing.

Sourcing Bash functions alone does not establish native behavior. Supplementary comparisons prove Go
execution through native helper or wiring checks. Their targets are defined in the [Makefile](../../../Makefile);
exact commands and results are recorded here and in the archived slice results.

`config_masked_reference.sh` invokes the production masked-config renderer with
synthetic files and worker callbacks. `test_config_masked.py` compares ordered
JSON, modes, warnings, cleanup and helper fallback. The original masking and
worker-config suites retain their Linux-only harness and remain unavailable on
macOS; these comparisons supplement them.

`worker_read_reference.sh` invokes the production worker read-credential renderer
with synthetic files and controlled host tools. `test_worker_read.py` compares
JSON, validation/HMAC callbacks, permissions, ownership and failure cleanup;
the unchanged worker-config suite remains unavailable under its Linux-only harness.

`preview_reference.sh` sources the production change-description and `.env` diff
functions with controlled config/host callbacks. `test_config_preview.py` compares
exact flags, messages, key lists, statuses and native/fallback selection;
`preview_contract_tests.py` supplies its protocol, locale and producer-failure
cases. Original config/approval suites retain their Linux-only harness and remain
unavailable on macOS; these new comparisons supplement them.

`payout_keys_reference.sh` sources the production public-view-key function and
ownership validator with supplied address-key results. `test_payout_keys.py`
compares curve vectors, invalid scalars, diagnostics, derived spend-key state and
helper fallback. The original payout-wallet-pairs suite remains unchanged under
its Linux-only harness; Docker-backed payout-pair startup checks are unavailable
locally. These comparisons supplement those contracts.

`env_read_reference.sh` calls the production dotenv decoder and getter with
synthetic byte fixtures; `test_env_read.py` compares decoding, first-key lookup,
diagnostics and helper fallback. `env_read_oracle_env.sh` supplies the Go hook
through `BASH_ENV` so the unchanged directory line-break suite's sourced helpers
reach native code. The original suite and its CLI/stub setup remain unchanged;
the broader unit-helper suite retains its unavailable Linux harness.

`compose_project_reference.sh` supplies environment/file fixtures to the production
resolver; `test_compose_project.py` compares names, warnings, statuses and fallback.
`compose_project_oracle_env.sh` loads the Go hook through `BASH_ENV` and fixes both
arms to the supported C locale so the unchanged lifecycle ownership suite's sourced
functions reach native code. Its engine remains the original function stub;
no running containers are involved.

`payout_ownership_reference.sh` supplies decoded-key fixtures and real public
addresses to `validate_payout_keys`; `test_payout_ownership.py`
compares verdicts, diagnostics, callbacks and retained spend-key state. The
existing payout-key comparison adapter already loads the extended production Go
hook and runs unchanged. The full wallet-pair suite retains its Linux harness.

`env_resources_reference.sh` reuses the original config JSON fixtures and supplies
synthetic core facts and peer settings. `test_env_resources.py` compares complete
environment bytes, diagnostics, callback order and helper fallback. Existing
memory/network comparisons and render goldens run unchanged; no hardware or
running containers are used.

`config_input_reference.sh` reaches the real parser entry point and stops after
its opening validation gates, before hardware or credential generation.
`test_config_input.py` compares diagnostics, error precedence, native selection
and fallback with disposable documents and helper stubs. Existing parser and
render suites remain unchanged.

`wallet_classifiers_reference.sh` calls the production wallet classifiers and
extracts the parser's unchanged diagnostic cases for paired gate comparisons.
`test_wallet_classifiers.py` reuses public addresses from the original CLI fixtures
and checks native selection, fallback, callback order and stdin-only helper input.
The original Monero/Tari domain and config-application suites retain their Linux
harness; the existing render fixture/goldens run unchanged.

`lifecycle_options_reference.sh` sources the generated CLI and replaces the first
operational callbacks with deterministic stops. `test_lifecycle_options.py`
compares argument handling, bytes, exit status, callback order and local state
with Bash, checks actual native success through a spy and exercises missing or
malformed helper fallback. `make test-go-lifecycle-options-parity` also runs the
unchanged CLI contract suite. The original lifecycle lock suite remains unchanged
and requires the Linux CLI harness; these comparisons do not prove operations.

`tari_secret_reference.sh` runs the production secret-publication block extracted
by `test_tari_secret.py`, with the current effective UID supplied for native
coverage. It compares file bytes, owner, mode, links, umask, dry-run and failure
callbacks, and checks the private stdin protocol and tool/helper fallback.
`make test-go-tari-secret-parity` also runs unchanged render/payout and CLI
comparisons. Original Linux Tari ownership/payout suites remain unchanged and
unavailable locally; the new comparisons supplement their future verdicts.

`test_tari_secret_ownership.py` reuses that adapter and extracted production block
with supplied UID/GID values and a failing sudo stub. It compares matching-owner
and foreign-owner paths, checks owned-helper selection, strict-helper retention,
framing and sentinel refusals, and checks temporary-file cleanup. Unprivileged
runs prove failed repair and Bash fallback; successful native chown requires a
privileged verdict. `make test-go-tari-ownership-parity` includes unchanged render
and CLI comparisons. No original suite or fixture changes.

`env_write_reference.sh` runs the native-publication branch extracted from
`render_env` by `test_env_write.py`, followed by the same mandatory chmod. It
compares bytes, inodes, links, owner/mode, umask, callback/error-trap behavior and
private stdin framing. A spy also checks native writes through the unchanged
render fixture. `make test-go-env-write-parity` includes existing env/render and
CLI comparisons; the original Linux lifecycle/config suites remain unchanged.

`config_version_publish_reference.sh` only sets a caller umask before executing
the unchanged version reference adapter. `test_config_version_publish.py`
compares atomic publication, native zero-argv invocation, bytes, owners, modes,
links, inode replacement, dry-run/no-op behavior and helper/tool fallback. A
different-group symlink case checks link ownership where permissions allow it;
temporary names, private paths and Bash diagnostic line numbers are normalized.
`make test-go-config-version-publish-parity` includes the unchanged version suite
and existing env/render and CLI comparisons. Original Linux suites stay unchanged.

`credentials_publish_reference.sh` sources the production credential writer and
Go bridge, supplying caller umasks, normal/conditional contexts and local failure
fixtures. `test_credentials_publish.py` compares fresh-stage publication, links,
existing-stage fallback, bytes/modes, dry-run, helper/tool failures, ERR traps and
final chmod failures after native publication. Credentials remain on stdin;
private paths and Bash diagnostic line numbers are normalized.
`make test-go-credentials-publish-parity` also runs the unchanged persistence suite
and existing env/render and CLI comparisons. Linux secrets/control suites stay
unchanged and unavailable locally.

## Dashboard HTTP foundation

`dashboard_http_plugin.py` is loaded explicitly for Go-selected pytest runs.
It wraps each original `create_app` fixture with a Go HTTP child and forwards
registered unported routes to the same Python app, preserving its state and
monkeypatches. It uses private inherited listeners, refuses absent/dead Go
binaries and reaps its exact child. Preview environment changes made inside a
Python test trigger a test-only child restart. Existing suites stay unchanged.

`dashboard_http_compare.py` supplements the oracle with full route/method and
control-registration cases, a sentinel reference proving native shell/static
ownership, and direct Python/Go byte/header comparisons for HEAD, ranges,
revalidation, normalized raw paths, missing paths and preview. An isolated
aiohttp stub proves actual Python-child bootstrap and exact-PID shutdown without
starting collectors or a database. `make test-go-dashboard-http-parity`
builds Go and runs these cases with the unchanged HTTP modules. The full
`make test-dashboard` can use the same plugin through `PYTEST_PLUGINS` and
`PYTHONPATH`; most service/view/JSON assertions still prove Python fallback,
not native Go state, polling or storage.

## Native chart and JSON handlers

`dashboard_state_plugin.py` layers on the unchanged HTTP plugin and installs
private raw inputs on the original Python app. Direct public `build_chart` calls
use the Go stdin helper so unchanged view tests exercise Go; marker iterables
are materialized exactly as the Python algorithm consumes them. HTTP state
requests capture chart inputs inside Python and call Go directly, preserving
one normal history read without launching a subprocess per request.

`dashboard_state_compare.py` compares native charts with the original Python
function across ranges, averaging windows, bucket rounding, gaps, shares and
other markers. It checks malformed helper refusal, empty mock iterables,
zero-based direct windows, private-route exclusion and raw query preservation.
For HTTP ownership it disables all four public Python handlers, then verifies
native state, connection, standby and metrics responses, one history read and
sanitized failures. `make test-go-dashboard-state-parity` also runs unchanged
chart and JSON route modules. Polling, storage, domain metrics and remaining
state sections still execute Python; these checks do not prove a full Go backend.

## Native dashboard domain metrics

`dashboard_metrics_plugin.py` layers over the unchanged state/HTTP adapters and
routes direct `build_metrics` and both history-average functions through Go
stdin helpers. It reconstructs the existing frozen dataclasses and reads the
same patched config/helper values, preserving the original fixture contracts.
HTTP requests use the production Go calculation directly. The plugin is selected
explicitly for the unchanged full dashboard suite.

`dashboard_metrics_compare.py` compares native results with the original Python
metrics and average functions, checks malformed-helper refusal, and makes every
Python `build_metrics` alias raise while `/api/state` and `/metrics` still
succeed. `make test-go-dashboard-domain-parity` runs these new cases, prior
comparisons and unchanged metrics/chart/JSON suites. Native runtime unit cases
check the private GET/POST handoff, raw query/history preservation, reject
percentages and failure boundaries. Polling, SQLite and remaining presentation
still use Python and are not proved native by these adapters.

## Native infrastructure and series presentation

`dashboard_views_plugin.py` layers over the metrics/state/HTTP adapters, routing
infrastructure builders and series helpers to Go. Signatures, fixtures,
dataclasses/namespaces and gated payout reads stay intact. Comparisons restore
the full Python builder graph for expected values.

`dashboard_average_session.py` keeps one Go average helper per worker to remove
process startup from property-test timing. Every input executes the unchanged
native calculation; no answers are cached. Its JSON stream has timeouts, child
cleanup and new Go tests. Existing helpers and adapters stay unchanged.

Under pytest-cov, the adapter reloads the views facade after tracing starts and
reapplies Go bindings before collection, recording previously untraced imports.
Coverage data, thresholds and the original suites stay unchanged.

`dashboard_views_compare.py` covers filtering, buckets, rounding, large numbers,
falsy timestamps, payout gates, node health, cards and malformed input. An HTTP
guard disables Python metrics, infrastructure and final series builders while
state succeeds. `make test-go-dashboard-views-parity` includes unchanged views,
location, metrics and JSON suites. Workers, energy, earnings, polling and storage
remain Python; this does not prove a complete native backend.

See [fleet and host-resource adapters](adapters-dashboard-fleet.md) for the next native state layer. [Overview and badge adapters](adapters-dashboard-overview.md) cover the next state fields.
