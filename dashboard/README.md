# Mining Dashboard

The monitoring web UI and XvB switching engine for Pithead. It aggregates stats from the local
collectors, the XMRig proxy, and the Tari node, and serves a single-page dashboard (behind Caddy)
on `127.0.0.1:8000`.

## Architecture

The server is a data API; the browser renders the UI. There is no server-side templating.

- `GET /` serves a tiny static HTML shell.
- `GET /api/state?range=…` returns the whole dashboard as JSON, the contract built by
  `views.build_state`. Computed domain values (effective hashrate, P2Pool/XvB averages, XvB tier
  qualification, shares-in-window, sync/down state) live in one typed place,
  `service/metrics.py` → `build_metrics() -> Metrics`. The view layer formats those into display
  strings and semantic tokens (`variant: "ok"`, `level: "high"`) and emits no HTML. The same
  `Metrics` is meant to back future consumers (Telegram #45, calculator #12) without re-deriving
  from the raw dict.
- Each `workers[]` row carries `mining`, the rig's own connection verdict (#4071):
  `{"state", "pool"}` with `state` one of `mining_here`, `on_backup`, `not_connected` or
  `unknown`. It is read from the `connection` block (`pool` as `host:port`, `uptime`) of the rig's
  summary feed, the shape rigforge's `tests/contract/v1/feed.json` pins. A live pool whose host
  is one of this host's names (`HOST_IP`, the detected host IPv4, a specific `STRATUM_BIND`, the
  host name and `<host name>.local`, so `pithead.local`, or loopback) is `mining_here` on
  `STRATUM_PORT` and `on_backup` on any other port. A pool at another IP address is `on_backup`
  once this host knows a non-loopback address of its own. A pool named by a host name the
  dashboard cannot match, or a pool string without a port, is `unknown`: it is never verified as
  foreign. `pool` carries the reported string. A rig with no live connection (`uptime` 0) is
  `not_connected`, and a rig that answers without a `connection` block is `unknown`. "Workers
  Alive" (`proxy_workers`), the total hashrate, the per-window totals and the "Mining paused
  here" header's backup-rig count use these verdicts: the counters take only stratum-side values
  of online rows that are not `on_backup` or `not_connected`. The rig's own hashrate is the
  separate `telemetry_h10`, `telemetry_h60` and `telemetry_h15` fields (H/s, `null` when not
  probed); it is never summed into a total, and `h60`/`h15` stay the proxy's figures.
  The Workers table (#4072) renders the verdict in each row as "on backup pool: <pool>", "not
  connected to this Pithead" or "mining location unknown", never lists a rig mining elsewhere as
  alive, and explains a `DOWN` row that still has telemetry as "telemetry only — not this
  Pithead" (or "no live connection here" when only the proxy's decaying rate remains). `telemetry_str` is the formatted `telemetry_h60`, shown in its own "Rig telemetry 1m"
  column. A proxy client with no rig name (`-` or empty) is a row named `unnamed proxy worker
  (<address>)` with `unnamed: true`, shown with its address and proxy hashrate and without a
  Worker Inspect link.
- The client (`static/dashboard.js` + `components.mjs`) is a small Preact app, rendered with `htm`
  tagged templates (no JSX, no build step). It polls `/api/state` every 30s and renders
  declaratively, so the chart instance, table sort, selected range, and the simple/advanced view
  all survive each refresh. UI state lives on the client; data lives on the server.

Everything is served from `/static`: the vendored Preact, htm and Chart.js (`static/vendor/`), plus
the app modules and `dashboard.css`. Nothing is inlined and the libraries are eval-free, so the
page runs under a strict Content-Security-Policy with no `'unsafe-inline'`/`'unsafe-eval'`.

Testing: the Python API, where the logic and formatting live, is unit-tested. The client-side
tests run under Node's built-in runner (`node --test dashboard/tests/frontend/`) — no
`package.json`/`node_modules`/build step, so the repo stays Node-free. They cover the pure logic
(`logic.test.mjs`: worker sort, tooltip formatting, hero-KPI selection), the chart helpers
(`chart.test.mjs`: `withAlpha`, `padYAxis`), the topology geometry (`topology.test.mjs`),
component rendering (`components.test.mjs`: every card driven through `App` against a real
`build_state()` fixture, via a DOM-free vnode walker), and the entry point
(`dashboard.test.mjs`: `initDashboard()` takes its browser seams — DOM, storage, fetch, history,
timer, render — as parameters with real defaults, so the poll loop, its hang-abort, and the
preference wiring run against fakes). The DOM-bound wiring (Chart.js canvas, the SVG topology
component) needs a browser and is left to a manual smoke test.

## Layout

```
mining_dashboard/
├── main.py            # entry point: build_app() wires everything; `python -m mining_dashboard.main`
├── config/            # configuration from environment variables
├── client/            # external service clients (xmrig, xmrig-proxy, xvb, tari gRPC, monerod RPC, docker control)
├── collector/         # local stats collectors (pools, system, docker logs)
├── service/           # algo_service (XvB switching), data_service (the aggregation poll loop),
│                      #   data_helpers (the pure parsers/aggregators behind that loop, plus
│                      #   WorkerLifecycle), storage_service (SQLite),
│                      #   metrics (typed computed domain values consumed by the view layer)
├── sim/               # donation_model (the XvB donation simulator; property-tested, #284)
├── web/               # server.py (transport: / shell + /api/state + middleware),
│                      #   views.py (build_state: the JSON state object), charts.py (the chart
│                      #   window/range hub views.py re-exports), xvb_views.py (XvB, earnings
│                      #   and top-bar badges), paused_badge.py (the "Mining paused here" line),
│                      #   infra_views.py (host, rig, energy, proxy,
│                      #   Tari and sync sections), series_views.py (share health, blocks,
│                      #   payouts, disk growth, XvB history, hashrate and cadence),
│                      #   templates/index.html (static shell),
│                      #   static/ (Preact app + dashboard.css + vendored libs)
└── helper/            # formatting utilities
```

It is an installable package (`pyproject.toml`): all internal imports are absolute
(`mining_dashboard.*`), and it runs as a module, with no `PYTHONPATH` gymnastics.

## Development

```bash
# from dashboard/ — uv creates .venv and installs from the hashed uv.lock (Python 3.11+)
uv sync --locked --extra test
```

Requests keeps its SOCKS support. The dependency metadata requires urllib3 2.8.0 or
newer for HTTPS proxy TLS isolation and bounded chunk-size parsing; `uv.lock` pins
the installed version. Regenerate the lock when changing dependency requirements.

## Tests

```bash
pytest                                   # quick run
pytest --cov=mining_dashboard --cov-report=term-missing --cov-fail-under=80

# client-side tests (needs only Node >= 18, no install):
node --test tests/frontend/
```

Or from the repo root: `make test-dashboard`. The same Python suite runs in the Docker test stage:

```bash
docker build --target test ./dashboard
```

Tests are hermetic: no network, no containers, no real database (an in-memory SQLite is used via
the `state_manager` fixture and the auto-applied DB-isolation fixture in `tests/conftest.py`).

Two coverage ratchets back the suite: a total floor (`--cov-fail-under=80`) and a patch gate
(`make test-patch-coverage` → `diff-cover` ≥ 90% on changed lines, #286). The money/numeric logic
(earnings, the XvB controller, the donation simulator) also has property-based tests (`hypothesis`, #284)
asserting invariants — non-negativity, conservation, monotonicity, clamp bounds — across a
wide input range, the class of bug example tests miss (cf. the #70 overshoot).

Typing roadmap (deferred): the app is lightly annotated today, so a static type-checker gate is
premature (and `ty` is still pre-1.0). The on-ramp — turning on ruff's `ANN` ruleset as a
non-blocking annotation ratchet, then adopting `ty`/`pyright` once coverage is meaningful and `ty`
reaches 1.0 — is a post-1.0 follow-up (#284), not a v1.1 blocker.

## Image

The `Dockerfile` is multi-stage:

- `base`: uv (digest-pinned) + system deps + lock/metadata + source.
- `test`: `uv sync --locked --extra test` then `pytest --cov-fail-under=80` (build with `--target test`).
- `production`: `uv sync --locked` (runtime deps only) + entrypoint (the default `docker compose build` target).
