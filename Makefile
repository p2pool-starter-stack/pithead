# Local test entry points (mirror the GitHub Actions CI jobs).
.DEFAULT_GOAL := pithead
.PHONY: go-build test-go test-go-parity go-cache test-go-status-parity test-go-doctor-parity test-go-doctor-memory-parity test-go-doctor-host-parity test-go-doctor-verification-parity test-go-doctor-control-parity test-go-doctor-disk-parity test-go-doctor-data-parity test-go-doctor-onion-parity test-go-config-access-parity test-go-doctor-config-parity test-go-doctor-network-parity test-go-doctor-lan-parity test-go-doctor-egress-parity test-go-doctor-nft-parity test-go-config-version-parity test-go-config-migrations-parity test-go-config-persistence-parity test-go-config-preview-parity test-go-payout-keys-parity test-go-env-read-parity test-go-compose-project-parity test-go-payout-ownership-parity test-go-env-resources-parity test-go-config-input-parity test-go-wallet-classifiers-parity test-go-lifecycle-options-parity test-go-tari-secret-parity test-go-env-write-parity test-go-tari-ownership-parity test-go-config-version-publish-parity test-go-credentials-publish-parity go-dashboard-build test-go-dashboard-http-parity test-go-dashboard-state-parity
.PHONY: test-go-doctor-history-parity test-go-doctor-containers-parity test-go-doctor-monero-parity test-go-node-monero-parity test-go-node-zmq-parity test-go-node-zmq-exchange-parity test-go-config-masked-parity test-go-config-document-parity test-go-config-defaults-parity test-go-config-validation-parity test-go-caddy-parity test-go-caddy-sites-parity test-go-wallet-settings-parity
.PHONY: test-go-env-parity test-go-env-network-parity test-go-env-dashboard-parity test-go-env-memory-parity test-go-site-names-parity test-go-stratum-parity test-go-network-settings-parity test-go-proxy-settings-parity test-go-caddy-auth-parity test-go-dashboard-access-parity test-go-dashboard-auth-parity test-go-directories-parity test-go-caddy-bind-parity test-go-payout-settings-parity test-go-worker-read-parity
go-dashboard-build: go-cache ## Build the incremental Go dashboard with Python fallback
	cd go && $(GO_ENV) go build -o bin/dashboard ./cmd/dashboard
test-go-dashboard-state-parity: go-dashboard-build ## Compare native chart and JSON contracts with unchanged Python suites
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_state_plugin tests/web/views/test_charts.py tests/web/test_server_state_api.py tests/web/test_server_xvb_standby_api.py tests/web/test_miner_connection.py tests/web/test_server_metrics_endpoint.py "$(CURDIR)/tests/go-parity/dashboard_state_compare.py"
test-go-dashboard-http-parity: go-dashboard-build ## Run unchanged dashboard HTTP tests through Go and supplementary comparisons
	cd dashboard && PITHEAD_IMPL=go PYTHONPATH="$(CURDIR)/tests/go-parity:$(CURDIR)/dashboard" uv run --locked --extra test python -m pytest -p dashboard_http_plugin tests/web/test_server_shell_route.py tests/web/test_server_static_assets.py tests/web/test_server_security_headers.py tests/web/test_server_control_routes_disabled.py tests/web/test_server_responsive_layout.py tests/web/views/test_sovereign_views.py "$(CURDIR)/tests/go-parity/dashboard_http_compare.py"
test-go-credentials-publish-parity: test-go-config-persistence-parity test-go-env-write-parity ## Compare credential publication and unchanged render contracts
	python3 tests/go-parity/test_credentials_publish.py
test-go-config-version-publish-parity: test-go-config-version-parity test-go-env-write-parity ## Compare config version publication and unchanged render contracts
	python3 tests/go-parity/test_config_version_publish.py
test-go-tari-ownership-parity: test-go-tari-secret-parity test-go-env-write-parity ## Compare native Tari ownership repair and unchanged render contracts
	python3 tests/go-parity/test_tari_secret_ownership.py
test-go-env-write-parity: test-go-env-parity test-go-parity ## Compare native env publication and unchanged render contracts
	python3 tests/go-parity/test_env_write.py
test-go-tari-secret-parity: test-go-env-parity test-go-payout-settings-parity test-go-parity ## Compare Tari secret publication and unchanged render contracts
	python3 tests/go-parity/test_tari_secret.py
test-go-lifecycle-options-parity: test-go-parity ## Compare lifecycle option handling and callback order with Bash
	python3 tests/go-parity/test_lifecycle_options.py
test-go-wallet-classifiers-parity: test-go-wallet-settings-parity test-go-env-parity ## Compare wallet classifier verdicts and unchanged render contracts
	python3 tests/go-parity/test_wallet_classifiers.py
test-go-config-input-parity: test-go-config-validation-parity test-go-config-document-parity ## Compare the parser input validation sequence with Bash
	python3 tests/go-parity/test_config_input.py
test-go-env-resources-parity: test-go-env-memory-parity ## Compare CPU render planning and peer bounds with Bash
	python3 tests/go-parity/test_env_resources.py
test-go-payout-ownership-parity: test-go-payout-keys-parity ## Compare payout ownership verdicts and retained spend-key state
	python3 tests/go-parity/test_payout_ownership.py
test-go-compose-project-parity: go-build test-go ## Compare Compose project identity and unchanged ownership checks
	python3 tests/go-parity/test_compose_project.py
	env BASH_ENV="$(CURDIR)/tests/go-parity/compose_project_oracle_env.sh" bash tests/stack/lifecycle/compose-project.sh
test-go-env-read-parity: go-build test-go ## Compare dotenv readers and run unchanged directory safeguards
	python3 tests/go-parity/test_env_read.py
	env BASH_ENV="$(CURDIR)/tests/go-parity/env_read_oracle_env.sh" bash tests/stack/standalone/test_directory_linebreaks.sh
test-go-payout-keys-parity: go-build test-go ## Compare payout public-view-key derivation with Python
	python3 tests/go-parity/test_payout_keys.py
test-go-config-preview-parity: go-build test-go ## Compare config change descriptions and env diffs with Bash
	python3 tests/go-parity/test_config_preview.py
test-go-worker-read-parity: go-build test-go ## Compare worker read-credential JSON and file behavior with Bash
	python3 tests/go-parity/test_worker_read.py
test-go-config-masked-parity: go-build test-go ## Compare masked config JSON and file behavior with Bash
	python3 tests/go-parity/test_config_masked.py
test-go-config-persistence-parity: go-build test-go ## Compare config persistence JSON and file behavior with Bash
	python3 tests/go-parity/test_config_persistence.py
	python3 tests/go-parity/test_config_persistence_aliases.py
	python3 tests/go-parity/test_config_write_aliases.py
test-go-config-migrations-parity: go-build test-go ## Compare config migration plans and file bytes with Bash
	python3 tests/go-parity/test_config_migrations.py
	python3 tests/go-parity/test_config_migrations_protocol.py
test-go-config-version-parity: go-build test-go ## Compare config version policy and stamped JSON with Bash
	python3 tests/go-parity/test_config_version.py
test-go-config-access-parity: go-build test-go ## Compare SSH policy and node credential parsing with Bash
	python3 tests/go-parity/test_config_access.py
	python3 tests/go-parity/test_config_access_render.py
test-go-site-names-parity: go-build test-go ## Compare shared Caddy host names and certificate SANs
	python3 tests/go-parity/test_site_names.py
	python3 tests/go-parity/test_site_names_render.py
test-go-wallet-settings-parity: go-build test-go ## Compare required-wallet config gates and render contracts
	python3 tests/go-parity/test_wallet_settings.py
	python3 tests/go-parity/test_wallet_settings_render.py
test-go-payout-settings-parity: go-build test-go ## Compare payout config validation and render contracts
	python3 tests/go-parity/test_payout_settings.py
	python3 tests/go-parity/test_payout_settings_render.py
test-go-caddy-bind-parity: go-build test-go ## Compare Caddy bind planning and unchanged render contracts
	python3 tests/go-parity/test_caddy_bind.py
test-go-directories-parity: go-build test-go ## Compare data directory derivation and safety gates with Bash
	python3 tests/go-parity/test_directories.py
	python3 tests/go-parity/test_directories_render.py
test-go-dashboard-auth-parity: go-build test-go ## Compare dashboard authentication and control policy with Bash
	python3 tests/go-parity/test_dashboard_auth.py
	python3 tests/go-parity/test_dashboard_auth_render.py
test-go-dashboard-access-parity: go-build test-go ## Compare dashboard access settings and timezone ordering with Bash
	python3 tests/go-parity/test_dashboard_access.py
	python3 tests/go-parity/test_dashboard_access_render.py
test-go-proxy-settings-parity: go-build test-go ## Compare proxy setting validation and partial state with Bash
	python3 tests/go-parity/test_proxy_settings.py
test-go-caddy-auth-parity: go-build test-go ## Compare Caddy auth preparation and rendered bytes with Bash
	python3 tests/go-parity/test_caddy_auth.py
test-go-network-settings-parity: go-build test-go ## Compare network settings validation and state with Bash
	python3 tests/go-parity/test_network_settings.py
test-go-stratum-parity: go-build test-go ## Compare stratum endpoint values and validation with Bash
	python3 tests/go-parity/test_stratum.py
test-go-env-memory-parity: go-build test-go ## Compare memory render values and unchanged render fixtures
	python3 tests/go-parity/test_env_memory.py
test-go-env-dashboard-parity: go-build test-go ## Compare dashboard render values and unchanged render fixtures
	python3 tests/go-parity/test_env_dashboard.py
test-go-env-network-parity: go-build test-go ## Compare network render values and unchanged render fixtures
	python3 tests/go-parity/test_env_network.py
test-go-env-parity: go-build test-go ## Compare bulk dotenv bytes with Bash and unchanged render fixtures
	python3 tests/go-parity/test_env_render.py
	python3 tests/go-parity/test_env_getters.py
test-go-caddy-parity: go-build test-go ## Compare Caddyfile bytes and render lifecycle with Bash
	python3 tests/go-parity/test_caddy.py
test-go-caddy-sites-parity: go-build test-go ## Compare native Caddy site and port preparation with Bash
	python3 tests/go-parity/test_caddy_sites.py
test-go-config-validation-parity: go-build test-go ## Compare typed config validation and diagnostics with Bash/jq
	python3 tests/go-parity/test_config_validation.py

test-go-config-defaults-parity: go-build test-go ## Compare defaults, legacy values and config getters with Bash/jq
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestDefaultsParity ./internal/config
	python3 tests/go-parity/test_config_defaults.py

test-go-config-document-parity: go-build test-go ## Compare raw config parsing and validation with Bash/Python
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestDocumentParity ./internal/config
	python3 tests/stack/lib/config-document-parser.py
	python3 tests/go-parity/test_config_document.py

test-go-node-zmq-exchange-parity: go-build test-go ## Compare bounded ZMTP stream I/O with Bash using local descriptors
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestZMQExchangeParity ./internal/nodeprobe

test-go-node-zmq-parity: go-build test-go ## Compare ZMTP greeting, READY and supplied handshake verdicts with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestZMQParity ./internal/nodeprobe

test-go-node-monero-parity: go-build test-go ## Compare remote Monero RPC preflight with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestMoneroRPCParity ./internal/nodeprobe

test-go-doctor-monero-parity: go-build test-go ## Compare Monero sync, peer and tip diagnostics with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestMoneroParity ./internal/doctor

test-go-doctor-containers-parity: go-build test-go ## Compare container restart and revenue-readiness findings with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestContainerParity ./internal/doctor

test-go-doctor-history-parity: go-build test-go ## Compare Tor history diagnostics and outage evidence with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestTorHistory ./internal/doctor ./internal/torhistory

test-go-doctor-nft-parity: go-build test-go ## Compare nft Tor-egress readback and sync-state selection with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run 'TestNFTEgress|TestTorSync' ./internal/firewall ./internal/doctor

test-go-doctor-egress-parity: go-build test-go ## Compare Docker Tor-egress readback and doctor reports with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestEgress ./internal/firewall ./internal/doctor

test-go-doctor-lan-parity: go-build test-go ## Compare LAN guard readback, boot holds and doctor findings with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestLAN ./internal/doctor

test-go-doctor-network-parity: go-build test-go ## Compare network diagnostic findings and probes with Bash using fake tools
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestNetwork ./internal/doctor

test-go-doctor-config-parity: go-build test-go ## Compare payout-address classification and config diagnostics with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestConfig ./internal/doctor

test-go-doctor-onion-parity: go-build test-go ## Compare Tor onion-address findings and status lines with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestOnion ./internal/doctor

test-go-doctor-data-parity: go-build test-go ## Compare missing data-directory and deployment findings with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestDataDirectory ./internal/doctor

test-go-doctor-disk-parity: go-build test-go ## Compare doctor and preflight disk checks with Bash using fake df
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestDisk ./internal/doctor

test-go-doctor-control-parity: go-build test-go ## Compare doctor control-unit and local-miner findings with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestControl ./internal/doctor

test-go-doctor-verification-parity: go-build test-go ## Compare doctor verifier and daemon availability with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestVerification ./internal/doctor

test-go-doctor-host-parity: go-build test-go ## Compare native doctor host and dependency probes with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run TestHost ./internal/doctor

test-go-doctor-memory-parity: go-build test-go ## Compare native doctor memory and clock probes with Bash
	cd go && $(GO_ENV) go test -tags=parity -count=1 -run Parity ./internal/doctor

test-go-doctor-parity: go-build test-go ## Compare Go doctor JSON reports with Bash using synthetic probes
	python3 tests/go-parity/test_doctor.py
test-go-status-parity: go-build test-go ## Compare native status with Bash against synthetic services
	python3 tests/go-parity/test_status.py
GO_ENV = env GOCACHE="$(CURDIR)/.go-cache/build" GOMODCACHE="$(CURDIR)/.go-cache/mod" GOPATH="$(CURDIR)/.go-cache/gopath" TMPDIR="$(CURDIR)/.go-cache/tmp"
go-cache:
	mkdir -p "$(CURDIR)/.go-cache/tmp"
go-build: pithead go-cache ## Build the Go CLI alongside the Bash reference
	cd go && $(GO_ENV) go build -o bin/pithead ./cmd/pithead
test-go: go-cache ## Go unit tests
	cd go && $(GO_ENV) go test ./...
test-go-parity: go-build test-go ## Compare Bash and Go CLI output, errors, and exit codes
	python3 tests/go-parity/test_cli.py
.PHONY: pithead test test-dashboard test-clearnet-replay-proof test-frontend test-browser test-patch-coverage test-stack test-netwatch test-compose test-integration test-integration-selftest test-tools test-inventory test-fakes test-mini-stack test-tari-config-parse test-container lint lint-sh lint-py lint-path-references lint-js lint-yaml lint-md lint-proto lint-toml lint-topology lint-file-budget lint-pithead-build lint-trivy-parity print-shellcheck-version print-shfmt-version release release-smoke

pithead: scripts/build-pithead.sh $(wildcard lib/pithead/*.sh) ## Build the generated CLI
	python3 scripts/build-config-defaults.py --check
	bash scripts/build-pithead.sh

test: lint test-dashboard test-frontend test-stack test-netwatch test-compose test-integration-selftest test-tools test-fakes ## Local checks (Docker required; no live test host)

test-dashboard: pithead ## Dashboard unit/component tests with coverage gate (deps from uv.lock); emits coverage.xml
	cd dashboard && uv run --locked --extra test python -m pytest -n auto \
		--cov=mining_dashboard --cov-report=term-missing --cov-report=xml --cov-fail-under=80

test-clearnet-replay-proof: ## Retained Linux ext4 proof of all 100 marker replay cases
	bash dashboard/tests/service/network/prove-clearnet-replay.sh

test-frontend: pithead ## Frontend logic tests with Node's built-in runner (#632; same invocation as CI)
	cd dashboard/tests/frontend && node --test

test-browser: ## Cross-browser GUI regressions (install locked dependencies first; see testing guide)
	cd dashboard/tests/browser && ./node_modules/.bin/playwright test
	node --test dashboard/tests/browser/backup-download.test.mjs

test-patch-coverage: ## diff-cover (#286) minus its vacuous pass (#1000): >=90% on changed lines (run after test-dashboard)
	bash scripts/lint/patch-coverage.sh

test-stack: pithead ## pithead shell test suite
	bash tests/stack/run.sh
	bash tests/stack/standalone/test_tor_recovery.sh
	bash tests/stack/standalone/test_tor_recovery_info.sh
	bash tests/stack/standalone/test_tor_bootstrap_recovery.sh
	bash tests/stack/standalone/test_tor_heal_outage_recovery.sh
	bash tests/stack/standalone/test_data_reset.sh
	bash tests/stack/standalone/test_directory_linebreaks.sh
	bash tests/stack/standalone/test_os_update_recovery.sh
	bash tests/stack/standalone/test_firstboot_journal.sh
	bash tests/stack/standalone/test_appliance_hugepages.sh
	bash tests/stack/standalone/test_grub_hugepages_real.sh
	python3 tests/stack/standalone/test_clearnet_attestation.py
	python3 tests/stack/standalone/test_stratum_port.py

test-netwatch: ## netwatch passive flow-audit: classifier verdicts + the test-tool coverage guard (no bench, no network)
	@# Tier 1 on purpose. The capture needs a bench; the JUDGEMENT does not, and the judgement is
	@# where a network audit goes wrong — a classifier that silently admits what it does not
	@# recognise reports a clean run on a leaking box. Driven against seeded flows instead.
	bash tests/netwatch/netwatch-selftest.sh
	@# And that the test-harness images stay tracked by dependabot + the CI CVE scan. Without this
	@# the images are "covered" only until someone edits a yaml, and nothing says otherwise.
	bash scripts/install-test-tools.sh --self-test

test-compose: pithead ## Validate Compose hardening and generated Caddyfiles
	bash tests/stack/standalone/test_compose.sh
	bash tests/stack/standalone/test_tari_wallet_permissions.sh
	bash tests/stack/standalone/test_caddyfile.sh

test-integration-selftest: pithead ## Integration harness logic and local transport fixtures (no live host needed)
	for t in tests/integration/selftest/*.sh; do bash "$$t" || { suite_rc=$$?; echo "$$t failed (exit $$suite_rc)" >&2; exit $$suite_rc; }; done
	for t in tests/os/selftest*.sh; do bash "$$t" || { suite_rc=$$?; echo "$$t failed (exit $$suite_rc)" >&2; exit $$suite_rc; }; done

test-tools:
	python3 tests/tools/test_lmdb_build.py
	bash scripts/lint/test-sanitize-test-log.sh
	bash scripts/lint/test-package-appliance.sh
	python3 scripts/lint/test-ci-uv-install.py
	python3 scripts/lint/test-browser-workflow.py
	python3 tests/stack/standalone/test_tor_saturated_fixture.py
	python3 tests/stack/standalone/test_monero_download.py
	python3 tests/stack/standalone/test_appliance_release_docs.py
	sed -n '/^  shell-block:$$/,/^  shell-fragment:$$/p' .github/workflows/shell.yml | grep -Eq '^    timeout-minutes: 15( |$$)'
	sed -n '/^  shell-fragment:$$/,/^  shell:$$/p' .github/workflows/shell.yml | grep -Eq '^    timeout-minutes: 12( |$$)'
	sed -n '/^  shell:$$/,/^  shell-standalone:$$/p' .github/workflows/shell.yml | grep -Eq '^    timeout-minutes: 5( |$$)'
	sed -n '/^  pull_request:$$/,/^permissions:$$/p' .github/workflows/integration-mini-stack.yml | grep -Fqx '      - "lib/pithead/**"'

test-fakes: ## Fake-daemon contract test — real dashboard clients vs controllable fakes (no docker)
	uv run --locked --project dashboard --extra test python -m pytest tests/integration/fakes -q

test-mini-stack: pithead ## Fake-daemon docker mini-stack end-to-end (needs docker; CI)
	bash tests/integration/mini-stack/run-mini-stack.sh
	bash tests/integration/mini-stack/test-boot-health-proxy.sh

test-tari-config-parse: pithead ## Feed the rendered Tari config to the pinned minotari_node image (needs docker; CI, #2341)
	bash tests/stack/standalone/test_tari_config_parse.sh

# The Linux toolchain as an image (#2078), so a contributor on macOS or Windows gets the verdict CI
# gets instead of the refusal #2041 installed. Pass any target or command through ARGS:
#   make test-container ARGS="make test-stack"   /   ARGS=bash   /   ARGS=--build
test-container: ## Run the suite in the pinned Linux image (any host with docker)
	bash scripts/test-container.sh $(ARGS)

test-inventory: ## Write the test coverage inventory to docs/dev/test-inventory.md (generated, git-ignored)
	bash tests/inventory.sh > docs/dev/test-inventory.md

# End-to-end matrix against a REAL test server (issue #54). Needs a provisioned box; pass
# connection + options through ARGS, e.g.:
#   make test-integration ARGS="--host miner@10.0.0.5 --dir pithead --lifecycle"
# See docs/dev/integration-testing.md.
test-integration: pithead ## Run the live config-matrix integration suite (requires a test box; pass ARGS=...)
	bash tests/integration/run.sh $(ARGS)

# The shellcheck version this repo's lint gate MEANS, and the ONE place it is written (#1679).
# `lint-sh` refuses to run on any other version, and ci.yml's installer derives its download URL
# from this variable (`make -s print-shellcheck-version`), so the pin cannot drift between the two.
# Bumping it here is most of the bump: ci.yml's sha256 line is tied to one tarball and fails loudly
# until it is updated to match.
SHELLCHECK_VERSION := 0.11.0

# shfmt, on the same terms and for the same reason (#1688): its formatting moves between releases,
# so a skewed version reds `make lint` on the release box for diffs the merge gate never saw. Was a
# literal in ci.yml until now. Bumping it here is likewise most of the bump — ci.yml's shfmt sha256
# is tied to one binary and fails loudly until it matches.
SHFMT_VERSION := 3.13.1

print-shellcheck-version: ## Print the pinned shellcheck version (ci.yml's installer reads this)
	@echo $(SHELLCHECK_VERSION)

print-shfmt-version: ## Print the pinned shfmt version (ci.yml's installer reads this)
	@echo $(SHFMT_VERSION)

lint: lint-sh lint-py lint-js lint-yaml lint-md lint-docs-voice lint-path-references lint-operator-strings lint-topology lint-file-budget lint-pithead-build lint-trivy-parity lint-proto lint-toml ## Lint/format-check every surface

# Shellcheck runs once per file, four at a time (#2632): a single invocation over every
# script accumulated memory across files (6.1 GB RSS) and used one core for ~351 s. `-x`
# keeps each file's sourced context, which a single invocation had supplied by following
# only the files it was handed. tests/stack/run.sh stays a separate call without `-x`:
# following its sources inlines the entire suite into one analysis root, which exhausted
# CI memory (#1333). List every module below so none escapes linting.
lint-sh: pithead ## shellcheck + shfmt over the CLI, build/* + dashboard/ container scripts, release + test scripts
	@# Refuse a version that is not the pin BEFORE linting anything: a different shellcheck reports
	@# different findings over identical files, so its verdict is not this gate's (#1679).
	@have=$$(shellcheck --version 2>/dev/null | awk '/^version:/ {print $$2}'); \
		[ "$$have" = "$(SHELLCHECK_VERSION)" ] || { \
			echo "lint-sh: shellcheck $${have:-not found} is not the pinned $(SHELLCHECK_VERSION) — its findings are not this gate's."; \
			echo "lint-sh: install the pin (see docs/dev/release-server.md) or run the gate in CI."; exit 1; }
	@# And shfmt, up here beside it rather than down at its own line: a wrong shfmt should not be
	@# discovered AFTER the shellcheck pass, which is the expensive half. `shfmt --version` prints a
	@# LEADING v on upstream release builds (v3.13.1) and a bare number on some distro builds
	@# (3.8.0) — both measured — so the comparison strips it instead of pinning the printed form.
	@have=$$(shfmt --version 2>/dev/null | sed 's/^v//'); \
		[ "$$have" = "$(SHFMT_VERSION)" ] || { \
			echo "lint-sh: shfmt $${have:-not found} is not the pinned $(SHFMT_VERSION) — its formatting is not this gate's."; \
			echo "lint-sh: install the pin (see docs/dev/release-server.md) or run the gate in CI."; exit 1; }
	printf '%s\0' pithead pithead-completion.bash install.sh scripts/*.sh scripts/*/*.sh build/*/*.sh dashboard/*.sh \
		tests/stack/lib.sh tests/stack/test-*.sh tests/stack/test_setup_build_interrupt.sh tests/stack/*/*.sh \
		tests/inventory.sh tests/integration/*.sh tests/integration/*/*.sh \
		os/installer/pithead-install os/build-image.sh os/rootfs/*.sh os/rauc/*.sh os/overlay/pithead-sync \
		os/overlay/pithead-data-reset os/overlay/pithead-mount-generator os/overlay/pithead-ssh-host-keys \
		os/overlay/pithead-machine-id os/overlay/pithead-media-config os/overlay/pithead-hugepages os/overlay/pithead-address-watch os/overlay/pithead-serial-port-present \
		os/overlay/pithead-journal-persist os/overlay/pithead-boot os/overlay/pithead-boot-stack-health os/overlay/pithead-boot-version \
		tests/os/*.sh tests/os/*/*.sh tests/netwatch/*.sh \
		| xargs -0 -n 1 -P 4 shellcheck -x --severity=warning
# CLI slices are checked through the generated pithead above: their semantic context
# depends on concatenation order. Listing them separately duplicates a large analysis
# and reports false unused-global warnings. shfmt checks every slice independently.
	shellcheck --severity=warning tests/stack/run.sh
	@# Three non-.sh files are named outright below, so a dead enumeration still hands shfmt
	@# three real arguments and exits 0 — 3 files checked of 100, reported as a pass. Guard the
	@# enumeration itself, the way lint-toml already does. (lint-yaml needs no guard: yamllint
	@# with no arguments is rc=2.)
	@test -n "$$(git ls-files '*.sh' | grep -v '^docs/research/')" || { echo "lint-sh: zero tracked *.sh files — refusing a vacuous pass"; exit 1; }
	shfmt -i 4 -d pithead pithead-completion.bash os/installer/pithead-install $(shell git ls-files '*.sh' | grep -v '^docs/research/')

lint-py: ## ruff lint + format check on all repo Python (ruff runs via uv from the locked dev extra)
	uv run --locked --project dashboard --extra dev ruff check .
	uv run --locked --project dashboard --extra dev ruff format --check .

lint-js: ## Biome lint + format check on the static frontend (config: biome.json)
	npx --yes @biomejs/biome@2.5.0 check .

lint-yaml: ## yamllint over all tracked YAML (config: .config/yamllint.yml)
	uvx yamllint -c .config/yamllint.yml $(shell git ls-files '*.yml' '*.yaml')

lint-md: ## markdownlint over all Markdown (config: .config/.markdownlint-cli2.jsonc)
	npx --yes markdownlint-cli2@0.18.1 --config .config/.markdownlint-cli2.jsonc

lint-docs-voice: ## Fail if banned marketing words appear in prose docs (house voice: docs/dev/STYLE.md)
	bash scripts/lint/lint-docs-voice.sh --self-test
	bash scripts/lint/lint-docs-voice.sh

lint-path-references: ## Fail if a repo path named in a comment, docstring, doc or `source` does not resolve (#1105, #2005)
	bash scripts/lint/lint-path-references.sh --self-test
	bash scripts/lint/lint-path-references.sh

lint-operator-strings: pithead ## Fail if a #NNN issue/PR number or a bare docs/ path leaks into pithead or dashboard operator-facing text (#755, #1024)
	bash scripts/lint/lint-operator-strings.sh --self-test
	bash scripts/lint/lint-operator-strings.sh

lint-topology: ## Fail if a real-looking IPv6/IPv4/hostname/path/user@host literal leaks into the repo (generic classes only)
	bash scripts/lint/lint-topology-classes.sh --self-test
	bash scripts/lint/lint-topology-classes.sh

lint-file-budget: ## Fail if a tracked file crosses the 800-line hard ceiling, or an existing offender grows past its docs/dev/file-budget.tsv ceiling (#1105 Phase 0)
	bash scripts/lint/lint-file-budget.sh --self-test
	FILE_BUDGET_BASE_REF="$$(git rev-parse HEAD)" bash scripts/lint/selftest-file-budget-release.sh
	bash scripts/lint/lint-file-budget.sh

lint-pithead-build: ## Test the generated CLI build and its ordering/refusal guards
	bash scripts/build-pithead.sh --self-test
lint-trivy-parity: ## Fail if a gate workflow's install-trivy version: (the one line that decides the engine) drifts from the version scripts/watch/trivyignore-watch.sh scans with (#1290), or if the cached-installer shape that makes it the only pin breaks (#2214)
	bash scripts/watch/trivyignore-watch.sh --self-test
	bash scripts/watch/trivyignore-watch.sh --check-parity
	bash scripts/lint/lint-trivy-installer-cache.sh --self-test
	bash scripts/lint/lint-trivy-installer-cache.sh
lint-proto: ## buf lint + build on the vendored Tari protos (config: .../tari/proto/buf.yaml)
	cd dashboard/mining_dashboard/client/tari/proto && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 lint && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 build
lint-toml: ## taplo TOML format check (config: .config/taplo.toml)
	@# Tracked files only, never a filesystem walk: taplo's walker panics on any unreadable
	@# dir (EACCES scandir — e.g. root-owned artifacts under .claude/ agent worktrees).
	@test -n "$$(git ls-files '*.toml')" || { echo "lint-toml: zero tracked TOML files — refusing a vacuous pass"; exit 1; }
	git ls-files -z '*.toml' | xargs -0 npx --yes @taplo/cli@0.7.0 fmt --check --config .config/taplo.toml
# Cut a release from the private build/test server — GHCR publish, gated on the test suite +
# the #54 integration matrix (issue #44). Pass options through ARGS, e.g. a safe plan-only preview:
#   make release ARGS="--dry-run"
# See docs/dev/releasing.md.
release: ## Cut a versioned release (build -> stage -> smoke -> promote -> publish). Pass ARGS=...
	bash scripts/release/release.sh $(ARGS)
# Post-publish smoke test (#459) — run ONCE, right after `make release` publishes vX.Y.Z. Real
# cosign verify of the published bundle + images, and (with ARGS="--upgrade DIR") the real #59
# one-click upgrade against a previous-release install. See docs/dev/releasing.md § Post-publish smoke.
#   make release-smoke                         # verify the just-published version's signature/bundle
#   make release-smoke ARGS="--upgrade /srv/code/previous"   # + drive the real #59 upgrade
release-smoke: ## Post-publish: real cosign verify + real #59 upgrade against the published bundle. Pass ARGS=...
	bash scripts/release/release-smoke.sh $(ARGS)
