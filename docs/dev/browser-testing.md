# Browser testing

The Playwright suite exercises production dashboard JavaScript in native browsers against local API fixtures.

Run the [installation commands](testing-guide.md#native-browser-regressions), then use the same
entry point as CI:

```bash
make test-browser
```

For one regression or browser:

```bash
cd dashboard/tests/browser
./node_modules/.bin/playwright test backup.test.mjs --project=webkit
./node_modules/.bin/playwright test osupdate-close.test.mjs --project=chromium --headed
```

## Coverage

| Area | Assertions | Live proof still required |
| --- | --- | --- |
| Dashboard | Earnings input grouping and malformed-input refusal, production entry point, view/theme persistence, chart range/averaging/series, failed first load and sustained disconnect/recovery, masked miner password | Served image identity, real telemetry, sync completion and rates |
| Configuration | Valid preview/apply payload and CSRF header, typed confirmation, cancel with no commit, malformed/duplicate JSON, secret sentinel preservation, transient restart, draft/invalid JSON preservation across views, dirty marker and reset | Host config transaction, validation, wallet preservation and conflicting tabs |
| Backup | Cancel with no mutation, in-flight duplicate/Escape blocking, transient polling failure, terminal failure/retry, actual synthetic kit/archive downloads, one-time secret removal | Caddy headers and authentication, real encryption/decryption/restore, browser download policy (#3271) |
| Workers | Dirty Escape gate, exact editable diff, refused noneditable key, native close/reopen | Worker enrolment, live process restart and restored hashrate |
| Diagnostics | Doctor and log requests, CSRF headers, transient polling failure, refusal/retry | Live doctor/repair meaning and redaction (#3262, #3277) |
| OS update | One-click error Close and focus return, busy Escape refusal, exact reboot confirmation, Later clears confirmation, host refusal | Signed bundle/slot writes, unattended boot/health/rollback (#3260), certificate trust (#3242) |

The Playwright journeys run in Chromium, Firefox, WebKit and a mobile Chromium viewport.
`make test-browser` also runs the separate Node HTTPS backup fixture in Chromium; CI repeats
that fixture with pinned Google Chrome for Testing. It retains certificate interstitial acceptance,
22 MiB encrypted download integrity, decryption/member checks and transfer-failure retries.
See [the testing guide](testing-guide.md#native-browser-regressions) for its prerequisites and limits. Mobile emulation
checks the same actions at a narrow viewport; it is not physical-device acceptance or a visual
screenshot comparison. Native chart rendering runs, but numerical chart contracts remain in the
frontend tests. See [testing strategy](testing-strategy.md) for the CLI, KVM and e2e tiers.

## Fixtures and failures

Each Playwright journey gets its own loopback server, browser context and synthetic state. The full-page tests
serve the production HTML and static assets and reuse the frontend state fixture. Component
journeys mount production controls and stub only their API boundaries. They never invoke product host-control commands. The separate HTTPS fixture uses local
OpenSSL and tar solely to generate and verify synthetic encrypted archives; those tools are required
by `make test-browser`. The shared Playwright fixture rejects external traffic and fails on missing static assets or
uncaught browser errors. These journeys use visible controls and native downloads, without
fixed sleeps or retries.

Playwright failure screenshots, traces and the HTML report are written to ignored `test-results/` and
`playwright-report/` directories. CI retains them for seven days. Inspect a local failure with:

```bash
cd dashboard/tests/browser
./node_modules/.bin/playwright show-report
./node_modules/.bin/playwright show-trace test-results/<failed-test>/trace.zip
```

Use only synthetic secrets in fixtures. Do not point these tests at an appliance or copy live
credentials into traces. `PITHEAD_BROWSER_STATIC=/absolute/path/to/static` serves alternate
production assets for negative controls, such as the old OS-update Close implementation.
A passing fixture suite does not replace manual GUI acceptance on an appliance and a disposable
sandbox. Keep remaining acceptance linked to its product issue; #3068 tracks wider release-test
automation debt, #3245 the appliance browser runner and #2402 viewport screenshots.
