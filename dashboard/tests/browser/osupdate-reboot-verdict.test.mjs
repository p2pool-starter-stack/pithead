// #3415: a terminal host verdict must supersede a stale local Rebooting phase on the same
// mounted component, after the bounded reconnect loop has given up.
import { expect, test } from "./fixtures.mjs";

const terminalVerdicts = [
  {
    name: "updated",
    verdict: { outcome: "updated", from: "1.0.0", to: "2.0.0", ts: 1 },
    banner: /System updated to v2\.0\.0/,
  },
  {
    name: "rolled back",
    verdict: { outcome: "rolled_back", from: "1.0.0", to: "2.0.0", ts: 2 },
    banner: /rolled back automatically/,
  },
];

async function mountUpdateHarness(ui) {
  await ui.mount(`
import { Component, createRef } from '/static/app/preact.mjs';
import { OsUpdateControl, OsVerdictBanner } from '/static/system/osupdate.mjs';

const pending = {
  step: 'reboot-pending',
  version: '2.0.0',
};

class Harness extends Component {
  constructor() {
    super();
    this.state = { os: pending, running: 'v1.0.0' };
    this.controlRef = createRef();
  }
  componentDidMount() {
    window.__initialOsUpdateControl = this.controlRef.current;
    window.__setOsUpdateProps = (os, running) => this.setState({ os, running });
  }
  componentDidUpdate() {
    window.__sameOsUpdateInstance =
      window.__initialOsUpdateControl === this.controlRef.current;
  }
  render() {
    return html\`<\${OsVerdictBanner} os=\${this.state.os} />
      <\${OsUpdateControl} ref=\${this.controlRef} os=\${this.state.os}
        version=\${{ text: this.state.running }} enabled=\${true} />\`;
  }
}

// Preserve the production reconnect loop and its 300 attempts while removing only wall-clock delay.
const realSetTimeout = window.setTimeout.bind(window);
window.setTimeout = (callback, delay, ...args) =>
  realSetTimeout(callback, delay === 2000 ? 0 : delay, ...args);
render(html\`<\${Harness} />\`, document.getElementById('fixture'));
`);
}

for (const terminal of terminalVerdicts) {
  test(`mounted terminal ${terminal.name} props clear an exhausted Rebooting modal`, async ({
    page,
    ui,
  }) => {
    let reconnectAttempts = 0;
    await page.route("**/api/control/os-update", (route) =>
      route.fulfill({ status: 202, json: { id: "fixture-reboot" } }),
    );
    await page.route("**/api/control/result?**", (route) =>
      route.fulfill({ json: { status: "rebooting" } }),
    );
    await page.route(/\/api\/state\?range=1h$/, (route) => {
      reconnectAttempts += 1;
      return route.fulfill({ status: 503, json: {} });
    });

    await mountUpdateHarness(ui);
    await page
      .getByRole("button", { name: "Reboot to finish the update to v2.0.0" })
      .click();
    const dialog = page.getByRole("dialog", { name: "System update" });
    await dialog.getByLabel(/Type REBOOT to confirm/).fill("REBOOT");
    await dialog.getByRole("button", { name: "Reboot now" }).click();

    await expect.poll(() => reconnectAttempts, { timeout: 20_000 }).toBe(300);
    // Positive control: a genuinely pending host remains in the Rebooting view after exhaustion.
    await expect(dialog.getByText(/Rebooting/)).toBeVisible();

    await page.evaluate((verdict) => {
      window.__setOsUpdateProps(
        { step: "idle", version: "2.0.0", verdict },
        verdict.outcome === "updated" ? "v2.0.0" : "v1.0.0",
      );
    }, terminal.verdict);

    await expect.poll(() => page.evaluate(() => window.__sameOsUpdateInstance)).toBe(true);
    // This control must run before the expected frozen-source failure: terminal props reached UI.
    await expect(page.getByText(terminal.banner)).toBeVisible();
    await expect(dialog.getByText(/Rebooting/)).toHaveCount(0);
  });
}
