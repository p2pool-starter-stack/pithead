# Reference-path changes for review

This inventory compares the working tree with frozen oracle base
`a73ffced33800de9435779a9cabef53864455acb`. Existing tests and fixtures are unchanged.
`M` means an existing reference path changed; `A` means a new helper or adapter.
Build/test wiring is included separately. The detailed parity ledger records
supported inputs, intentional compatibility paths and native ownership proof.

## CLI reference and helper adapters

The public selector, private hybrid marker and inherited ignored signals affect launch/fallback. The G7 bare-status locale preflight keeps invalid locales in the original Bash process, avoiding a repeated startup warning; Go checks actual UTF-8 character maps before native formatting. Supported config, env/Caddy and lifecycle policy delegate through bounded adapters; providers, tool interpositions, locks, filesystem effects and Compose remain Bash. The firstboot change this round removes comments only; its parsed function is identical.

| Status | Path |
|---|---|
| M | `lib/pithead/00-prelude.sh` |
| M | `lib/pithead/01-lifecycle.sh` |
| A | `lib/pithead/01a-go-keep-running.sh` |
| M | `lib/pithead/06-doctor.sh` |
| M | `lib/pithead/12-firstboot-wizard.sh` |
| M | `lib/pithead/19-small-utilities.sh` |
| M | `lib/pithead/19a-config-defaults.sh` |
| A | `lib/pithead/19b-go-env-read.sh` |
| A | `lib/pithead/19c-go-compose-project.sh` |
| M | `lib/pithead/22a-config-document.sh` |
| M | `lib/pithead/23-setup-and-credentials.sh` |
| M | `lib/pithead/25-address-types.sh` |
| A | `lib/pithead/25a-go-address-types.sh` |
| M | `lib/pithead/25b-payout-keys.sh` |
| A | `lib/pithead/25c-go-payout-keys.sh` |
| M | `lib/pithead/26-appliance-tls-provisioning.sh` |
| A | `lib/pithead/26a-go-site-names.sh` |
| M | `lib/pithead/27-defaults-and-config-validation.sh` |
| M | `lib/pithead/27a-config-version.sh` |
| M | `lib/pithead/27b-stratum-endpoint.sh` |
| A | `lib/pithead/27d-go-network-settings.sh` |
| A | `lib/pithead/27e-go-proxy-settings.sh` |
| A | `lib/pithead/27f-go-dashboard-access.sh` |
| A | `lib/pithead/27g-go-dashboard-auth.sh` |
| A | `lib/pithead/27h-go-directories.sh` |
| A | `lib/pithead/27i-go-payout-settings.sh` |
| A | `lib/pithead/27j-go-wallet-settings.sh` |
| A | `lib/pithead/27k-go-config-access.sh` |
| A | `lib/pithead/27l-go-config-version.sh` |
| A | `lib/pithead/27m-go-config-migrations.sh` |
| A | `lib/pithead/27n-go-config-persistence.sh` |
| A | `lib/pithead/27o-go-config-input.sh` |
| M | `lib/pithead/28-parse-and-validate-config.sh` |
| M | `lib/pithead/30-release-fetch-and-masked-config.sh` |
| A | `lib/pithead/30a-go-masked-config.sh` |
| A | `lib/pithead/30b-go-worker-read.sh` |
| M | `lib/pithead/33-render-env.sh` |
| A | `lib/pithead/33a-go-env-render.sh` |
| A | `lib/pithead/33b-go-env-network.sh` |
| A | `lib/pithead/33c-go-env-dashboard.sh` |
| A | `lib/pithead/33d-go-env-memory.sh` |
| A | `lib/pithead/33e-go-tari-secret.sh` |
| A | `lib/pithead/33f-go-env-write.sh` |
| M | `lib/pithead/35-caddyfile-and-auth-helpers.sh` |
| A | `lib/pithead/35a-caddy-go-render.sh` |
| A | `lib/pithead/35b-caddy-go-auth.sh` |
| A | `lib/pithead/35c-caddy-go-bind.sh` |
| M | `lib/pithead/39-describe-change.sh` |
| A | `lib/pithead/39c-go-preview.sh` |
| A | `lib/pithead/39d-go-lifecycle-options.sh` |
| M | `lib/pithead/40-apply-and-render.sh` |
| M | `lib/pithead/51-main-dispatch.sh` |

## Dashboard Python reference

Review the provider seams and extracted telemetry/revision helpers against the frozen Python behavior. Native installation changes bindings only in Go selection. Reference mode retains Python providers, clocks, callbacks and orchestration. The new go_*.py bridge modules are separately listed below.

| Status | Path |
|---|---|
| M | `dashboard/mining_dashboard/helper/utils.py` |
| M | `dashboard/mining_dashboard/service/audit_service.py` |
| M | `dashboard/mining_dashboard/service/config_operations.py` |
| M | `dashboard/mining_dashboard/service/control_service.py` |
| M | `dashboard/mining_dashboard/service/data_audit.py` |
| M | `dashboard/mining_dashboard/service/data_service.py` |
| M | `dashboard/mining_dashboard/service/metrics.py` |
| M | `dashboard/mining_dashboard/service/network/egress_status.py` |
| M | `dashboard/mining_dashboard/service/storage_service.py` |
| A | `dashboard/mining_dashboard/service/telemetry_capture.py` |
| M | `dashboard/mining_dashboard/service/workers/worker_change_audit.py` |
| M | `dashboard/mining_dashboard/service/workers/worker_config_store.py` |
| A | `dashboard/mining_dashboard/service/workers/worker_revision_store.py` |
| M | `dashboard/mining_dashboard/web/views/charts.py` |
| M | `dashboard/mining_dashboard/web/views/views.py` |
| M | `dashboard/mining_dashboard/web/views/xvb_calculator.py` |
| M | `dashboard/mining_dashboard/web/views/xvb_views.py` |
| M | `dashboard/mining_dashboard/wizard/server.py` |

## Shipping and selection

These changes package and select the optional Go build while preserving Bash/Python fallback. They do not port appliance host logic or the container entrypoint. Published bundles, complete appliance boot and AMD64 execution remain unproven.

| Status | Path |
|---|---|
| A | `.dockerignore` |
| M | `dashboard/Dockerfile` |
| M | `dashboard/entrypoint.sh` |
| M | `docker-compose.yml` |
| M | `os/build-image.sh` |
| M | `os/rootfs/Dockerfile` |
| M | `scripts/release/bundle.sh` |
| M | `scripts/release/images.sh` |

## New Python bridge modules

All of these modules count toward the unchanged `--cov=mining_dashboard` gate.
The ordinary bridge contract tests run in both selections; native ownership
requires the focused source-fatal/body/mutation proofs in the detailed ledger.
The runtime still needs a Python child. This round changes only the transaction
bridge to retain explicitly interposed OS I/O behavior.

- `dashboard/mining_dashboard/go_access_log.py`
- `dashboard/mining_dashboard/go_audit_cap.py`
- `dashboard/mining_dashboard/go_audit_query.py`
- `dashboard/mining_dashboard/go_bridge.py`
- `dashboard/mining_dashboard/go_channel.py`
- `dashboard/mining_dashboard/go_config_meta.py`
- `dashboard/mining_dashboard/go_control.py`
- `dashboard/mining_dashboard/go_control_http.py`
- `dashboard/mining_dashboard/go_control_outcomes.py`
- `dashboard/mining_dashboard/go_documents.py`
- `dashboard/mining_dashboard/go_domain.py`
- `dashboard/mining_dashboard/go_earnings.py`
- `dashboard/mining_dashboard/go_editor.py`
- `dashboard/mining_dashboard/go_egress_status.py`
- `dashboard/mining_dashboard/go_fleet.py`
- `dashboard/mining_dashboard/go_forecast.py`
- `dashboard/mining_dashboard/go_network.py`
- `dashboard/mining_dashboard/go_network_validation.py`
- `dashboard/mining_dashboard/go_overview.py`
- `dashboard/mining_dashboard/go_polling.py`
- `dashboard/mining_dashboard/go_preserve.py`
- `dashboard/mining_dashboard/go_revision_store.py`
- `dashboard/mining_dashboard/go_rigforge.py`
- `dashboard/mining_dashboard/go_snapshot.py`
- `dashboard/mining_dashboard/go_state.py`
- `dashboard/mining_dashboard/go_state_executor.py`
- `dashboard/mining_dashboard/go_storage.py`
- `dashboard/mining_dashboard/go_views.py`
- `dashboard/mining_dashboard/go_wizard.py`
- `dashboard/mining_dashboard/go_wizard_config.py`
- `dashboard/mining_dashboard/go_wizard_policy.py`
- `dashboard/mining_dashboard/go_wizard_preparation.py`
- `dashboard/mining_dashboard/go_wizard_state.py`
- `dashboard/mining_dashboard/go_wizard_submission.py`
- `dashboard/mining_dashboard/go_wizard_terminal.py`
- `dashboard/mining_dashboard/go_wizard_transaction.py`
- `dashboard/mining_dashboard/go_wizard_typed.py`
- `dashboard/mining_dashboard/go_wizard_values.py`
- `dashboard/mining_dashboard/go_worker_detail.py`
- `dashboard/mining_dashboard/go_worker_http.py`

## Build and test wiring

Review `Makefile`, `.github/workflows/ci.yml`, the reusable Go workflow and its
source/test discovery alongside the shipping paths above. Existing checks are
retained. New tests under `tests/go-parity/` and `dashboard/tests/bridges/` are
supplementary; they are not relabeled as unchanged suites.

The 2026-11-02 pinned-runner continuation changes `scripts/test-container.sh` to
provide `RUNNER_TEMP` and run its supplied command with the dashboard's locked
Python dependencies. Its virtualenv lives inside the disposable container;
the host's `dashboard/.venv` is not modified. Review this launcher change
separately from application parity and appliance behavior.
The launcher also uses `--init` to reap orphaned test children.
An additive tools-image layer supplies real Go, systemd, C build tools and envsubst;
its Go source uses the existing appliance-builder image digest. The original
runner Dockerfile remains frozen; review `scripts/test-runner-tools.Dockerfile`
and its signed, dated package snapshot. `container_bridge_addrs` in
`lib/pithead/19-small-utilities.sh` replaces an awk interval with an equivalent
length and character check because the pinned runner's older mawk rejects it.

Earlier port rounds add typed-wizard counter compatibility in `dashboard/conftest.py`,
active only with the existing Go channel parity plugin. A separate new
`tests/go-parity/conftest.py` isolates the minimal child package. Neither changes
production JSON or the normal dashboard application bindings. `.config/.markdownlint-cli2.jsonc` excludes
generated Go/uv caches; a malformed project-source mutation still fails.
`docs/dev/file-budget.tsv` restores the firstboot ceiling to 476 and records the
unchanged browser-submit test at its actual 406 lines.
