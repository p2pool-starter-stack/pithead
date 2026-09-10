# Local test entry points (mirror the GitHub Actions CI jobs).
.DEFAULT_GOAL := pithead
.PHONY: pithead test test-dashboard test-frontend test-patch-coverage test-stack test-compose test-integration test-integration-selftest test-tools test-inventory test-fakes test-mini-stack lint lint-sh lint-py lint-path-references lint-js lint-yaml lint-md lint-proto lint-toml lint-topology lint-file-budget lint-pithead-build lint-trivy-parity print-shellcheck-version print-shfmt-version release release-smoke

pithead: scripts/build-pithead.sh $(wildcard lib/pithead/*.sh) ## Build the generated CLI
	bash scripts/build-pithead.sh

test: lint test-dashboard test-frontend test-stack test-compose test-integration-selftest test-tools test-fakes ## Local checks (Docker required; no live test host)

test-dashboard: pithead ## Dashboard unit/component tests with coverage gate (deps from uv.lock); emits coverage.xml
	cd dashboard && uv run --locked --extra test python -m pytest \
		--cov=mining_dashboard --cov-report=term-missing --cov-report=xml --cov-fail-under=80

test-frontend: pithead ## Frontend logic tests with Node's built-in runner (#632; same invocation as CI)
	cd dashboard/tests/frontend && node --test

test-patch-coverage: ## diff-cover (#286) minus its vacuous pass (#1000): >=90% on changed lines (run after test-dashboard)
	bash scripts/lint/patch-coverage.sh

test-stack: pithead ## pithead shell test suite
	bash tests/stack/run.sh
	bash tests/stack/standalone/test_data_reset.sh
	bash tests/stack/standalone/test_os_update_recovery.sh
	bash tests/stack/standalone/test_firstboot_journal.sh
	bash tests/stack/standalone/test_appliance_hugepages.sh

test-compose: pithead ## Validate docker-compose.yml interpolation + hardening invariants (#90)
	bash tests/stack/standalone/test_compose.sh

test-integration-selftest: pithead ## Integration harness pure-logic self-test (no server needed)
	# Globbed, not enumerated — the same reason as ci.yml: an enumerated list silently omits
	# any self-test added later, and a check that never runs reads exactly like one that passed.
	for t in tests/integration/selftest/*.sh; do bash "$$t" || exit 1; done
	for t in tests/os/selftest*.sh; do bash "$$t" || exit 1; done

test-tools: ## Bounded-log sanitizer contract (no services or dependencies)
	bash scripts/lint/test-sanitize-test-log.sh

test-fakes: ## Fake-daemon contract test — real dashboard clients vs controllable fakes (no docker)
	uv run --locked --project dashboard --extra test python -m pytest tests/integration/fakes -q

test-mini-stack: ## Fake-daemon docker mini-stack end-to-end (needs docker; CI)
	bash tests/integration/mini-stack/run-mini-stack.sh

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

# Keep tests/stack/run.sh out of the invocation containing its sourced modules.
# Shellcheck otherwise inlines the entire suite into a single analysis root, which
# exhausted CI memory (#1333). List every module below so none escapes linting.
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
	shellcheck --severity=warning pithead pithead-completion.bash install.sh scripts/*.sh scripts/*/*.sh build/*/*.sh dashboard/*.sh \
		tests/stack/lib.sh tests/stack/test-*.sh tests/stack/*/*.sh \
		tests/inventory.sh tests/integration/*.sh tests/integration/*/*.sh \
		os/installer/pithead-install os/build-image.sh os/rauc/*.sh os/overlay/pithead-sync \
		os/overlay/pithead-data-reset os/overlay/pithead-mount-generator os/overlay/pithead-ssh-host-keys \
		os/overlay/pithead-machine-id os/overlay/pithead-media-config os/overlay/pithead-hugepages \
		os/overlay/pithead-journal-persist os/overlay/pithead-boot \
		tests/os/*.sh tests/os/*/*.sh
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

lint-yaml: ## yamllint over all tracked YAML (config: .yamllint)
	uvx yamllint $(shell git ls-files '*.yml' '*.yaml')

lint-md: ## markdownlint over all Markdown (config: .markdownlint-cli2.jsonc)
	npx --yes markdownlint-cli2@0.18.1

lint-docs-voice: ## Fail if banned marketing words appear in prose docs (house voice: docs/dev/STYLE.md)
	bash scripts/lint/lint-docs-voice.sh --self-test
	bash scripts/lint/lint-docs-voice.sh

lint-path-references: ## Fail if a repo path named in a comment, docstring or doc does not resolve (#1105)
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
	bash scripts/lint/lint-file-budget.sh

lint-pithead-build: ## Test the generated CLI build and its ordering/refusal guards
	bash scripts/build-pithead.sh --self-test

lint-trivy-parity: ## Fail if ci.yml's and os-rootfs.yml's trivy-action steps drift from the version scripts/watch/trivyignore-watch.sh scans with (#1290)
	bash scripts/watch/trivyignore-watch.sh --self-test
	bash scripts/watch/trivyignore-watch.sh --check-parity

lint-proto: ## buf lint + build on the vendored Tari protos (config: .../tari/proto/buf.yaml)
	cd dashboard/mining_dashboard/client/tari/proto && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 lint && \
		docker run --rm -v "$$PWD":/workspace --workdir /workspace bufbuild/buf:1.71.0 build

lint-toml: ## taplo TOML format check (config: .taplo.toml)
	@# Tracked files only, never a filesystem walk: taplo's walker panics on any unreadable
	@# dir (EACCES scandir — e.g. root-owned artifacts under .claude/ agent worktrees).
	@test -n "$$(git ls-files '*.toml')" || { echo "lint-toml: zero tracked TOML files — refusing a vacuous pass"; exit 1; }
	git ls-files -z '*.toml' | xargs -0 npx --yes @taplo/cli@0.7.0 fmt --check

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
