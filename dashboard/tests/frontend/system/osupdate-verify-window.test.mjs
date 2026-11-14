import assert from "node:assert/strict";
import { test } from "node:test";

import { osBadgeLabel } from "../../../mining_dashboard/web/static/system/osreboot.mjs";
import { OsUpdateControl, OsVerdictBanner } from "../../../mining_dashboard/web/static/system/osupdate.mjs";
import { renderToString } from "../helpers/render.mjs";

const flat = (s) => s.replace(/\s+/g, " ");

function inst(props) {
  const c = new OsUpdateControl(props);
  c.props = props;
  return c;
}

test("the badge names the verify window and asks for no action", () => {
  assert.equal(
    osBadgeLabel({ step: "verifying", version: "1.19.0" }),
    "Verifying the update to v1.19.0 — leave the machine running",
  );
  assert.equal(
    osBadgeLabel({ step: "verifying" }),
    "Verifying the update to the installed release — leave the machine running",
  );
  assert.equal(
    osBadgeLabel({ step: "reboot-pending", version: "1.19.0" }),
    "Reboot to finish the update to v1.19.0",
  );
});

test("a verifying step maps to its own pane phase", () => {
  assert.equal(inst({ os: { step: "verifying", version: "1.19.0" }, enabled: true }).stepPhase(), "slot-verifying");
  assert.equal(inst({ os: { step: "reboot-pending", version: "1.19.0" }, enabled: true }).stepPhase(), "reboot-pending");
});

test("the open pane while verifying says leave the machine running and offers no reboot", () => {
  const c = inst({
    os: { step: "verifying", version: "1.19.0", from: "1.18.1" },
    update: { available: true, latest: "v1.19.0" },
    version: { text: "1.19.0" },
    enabled: true,
  });
  c.state.phase = "slot-verifying";
  const out = flat(renderToString(c.render()));
  assert.match(out, /Verifying v1\.19\.0 — leave the machine running/);
  assert.match(out, /health checks are still running/);
  assert.match(out, /returns to the previous one on its own/);
  assert.doesNotMatch(out, /Reboot to finish|Reboot now|> *Download|Verify REBOOT|Type REBOOT/);
});

test("the badge opens straight to the verify pane for a verifying step", () => {
  const c = inst({ os: { step: "verifying", version: "1.19.0" }, enabled: true });
  c.setState = (patch) => {
    c.state = { ...c.state, ...patch };
  };
  const rendered = renderToString(c.render());
  assert.match(rendered, /Verifying the update to v1\.19\.0 — leave the machine running/);
  const badge = c.render()[0];
  badge.props.onClick();
  assert.equal(c.state.phase, "slot-verifying");
  assert.match(flat(renderToString(c.render())), /leave the machine running/);
  assert.doesNotMatch(flat(renderToString(c.render())), /Reboot to finish/);
});

test("the closed badge itself carries the verify window, no modal needed", () => {
  const out = flat(
    renderToString(
      inst({
        os: { step: "verifying", version: "1.19.0" },
        update: { available: true, latest: "v1.19.0" },
        enabled: true,
      }).render(),
    ),
  );
  assert.match(out, /badge-accent/);
  assert.match(out, /Verifying the update to v1\.19\.0 — leave the machine running/);
  assert.doesNotMatch(out, /Reboot to finish/);
});

test("the idle pane with a verifying step offers no Download and no Reboot to finish", () => {
  const c = inst({
    os: { step: "verifying", version: "1.19.0" },
    update: { available: true, latest: "v1.19.0", raucb_size: 1000 },
    version: { text: "1.19.0" },
    enabled: true,
  });
  c.state.phase = "idle";
  const out = flat(renderToString(c.render()));
  assert.match(out, /Check now/);
  assert.doesNotMatch(out, /Download|Reboot to finish/);
});

test("the banner renders the interrupted sentence, not a health-check failure", () => {
  const out = flat(
    renderToString(
      OsVerdictBanner({
        os: {
          step: "idle",
          verdict: { outcome: "rolled_back", from: "1.18.1", to: "1.19.0", interrupted: true, ts: 5 },
        },
      }),
    ),
  );
  assert.match(out, /interrupted before its verification finished/);
  assert.match(out, /never reached a verdict/);
  assert.doesNotMatch(out, /failed its health checks/);
});
