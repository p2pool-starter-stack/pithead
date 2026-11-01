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
