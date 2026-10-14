# Launch assets

Launch visuals for the Pithead dashboard (Issue #80). Static views ship in dark and light
themes (`*-light.png`), so docs can serve a theme-adaptive `<picture>`.

| Asset | Files | What |
|---|---|---|
| **Hero** | `hero.png` / `hero-light.png` | Header + hero KPI band (wide banner) |
| **Simple** | `simple.png` / `simple-light.png` | Operational view, Simple tab (default) |
| **Advanced** | `advanced.png` / `advanced-light.png` | Operational view, Advanced tab (power-user cards) |
| **Sync** | `sync.png` / `sync-light.png` | Sync Mode (nodes catching up, miner held) |
| **Demo GIF** | `demo.gif` | ~12s scroll-tour of the Advanced dashboard (600×338) |
| **Social preview** | `social-preview.png` | 1280×640 card for GitHub's repo social preview (Settings → Social preview) |

These are not hand-drawn mockups: every static view and the demo GIF is a headless-browser capture
of the real dashboard UI (the shipping Preact components + `dashboard.css`), fed the same
`/api/state` fixture the frontend render tests use
(`dashboard/tests/frontend/fixtures/state.json`), so they are pixel-accurate to the product. The
numbers (a 10 kH/s farm, two workers, etc.) and the wallet/host values are the fixture's — fabricated
for presentation, never real wallet, host, or operator data (wallet fields are obvious `EXAMPLE`
placeholders).

Regenerate all nine files (light/dark pairs + demo GIF) with:

    npm install playwright --prefix /tmp/pw-capture   # scratch dir; not a project dependency
    ln -s /tmp/pw-capture/node_modules dashboard/tests/frontend/fixtures/node_modules
    node dashboard/tests/frontend/fixtures/_capture_launch_images.mjs
    rm dashboard/tests/frontend/fixtures/node_modules

`social-preview.png` is a separate hand-designed marketing card, not a dashboard capture, and stays
that way.

Static views rendered at retina 2× (`hero*` 2880×600; `sync*` 2880×1336; `simple*`/`advanced*`
full-page at 1×). Used in the [README](../../../README.md) (hero + demo GIF) and
[docs/dashboard.md](../../dashboard.md) (Simple / Advanced / Sync).

> NOTE: `social-preview.png` is not wired up automatically. GitHub's repo social-preview image can
> only be set from the web UI: repo → Settings → General → Social preview → Edit → upload
> `social-preview.png`.
