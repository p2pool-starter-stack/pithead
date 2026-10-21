// #3415: a terminal host verdict supersedes the tab's local Rebooting phase; a pending reboot
// does not. Run with: node --test dashboard/tests/frontend/*.test.mjs
import assert from "node:assert/strict";
import { test } from "node:test";

import { hostAnswered } from "../../../mining_dashboard/web/static/system/osreboot.mjs";
import { OsUpdateControl } from "../../../mining_dashboard/web/static/system/osupdate.mjs";

const verdict = (outcome, ts) => ({ outcome, from: "1.0.0", to: "2.0.0", ts });

test("hostAnswered accepts only a fresh terminal verdict on an idle step", () => {
  assert.equal(hostAnswered({ step: "idle", verdict: verdict("updated", 1) }), true);
  assert.equal(hostAnswered({ step: "idle", verdict: verdict("rolled_back", 2) }), true);
  assert.equal(hostAnswered({ step: "reboot-pending", version: "2.0.0" }), false);
  assert.equal(hostAnswered({ step: "idle" }), false);
  assert.equal(hostAnswered(null), false);
  assert.equal(hostAnswered({ step: "reboot-pending", verdict: verdict("updated", 1) }), false);
  // the verdict the reboot began under belongs to an earlier update
  assert.equal(hostAnswered({ step: "idle", verdict: verdict("updated", 1) }, 1), false);
});

test("componentDidUpdate closes a Rebooting modal only once the host has answered", () => {
  const cases = [
    [{ step: "idle", verdict: verdict("updated", 1) }, "rebooting", "closed"],
    [{ step: "idle", verdict: verdict("rolled_back", 2) }, "rebooting", "closed"],
    [{ step: "reboot-pending", version: "2.0.0" }, "rebooting", "rebooting"],
    [{ step: "idle", verdict: verdict("updated", 1) }, "error", "error"],
  ];
  for (const [os, phase, want] of cases) {
    const props = { os, enabled: true };
    const c = new OsUpdateControl(props);
    c.props = props;
    c.state.phase = phase;
    let next = phase;
    c.setState = (patch) => {
      next = patch.phase;
    };
    c.componentDidUpdate();
    assert.equal(next, want, JSON.stringify([os, phase]));
  }
});
