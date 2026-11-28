import assert from "node:assert/strict";
import { test } from "node:test";

import { WorkerInspect } from "../../../mining_dashboard/web/static/workers/workerview.mjs";
import { renderToString } from "../helpers/render.mjs";
import { stubSetState } from "./workerview-helpers.mjs";

const RIG_ID = "0123456789abcdef0123456789abcdef";

function adoptRender(extra) {
  const inst = new WorkerInspect({ name: "rig1", onClose: () => {} });
  stubSetState(inst);
  const detail = {
    name: "rig1",
    found: true,
    status: "online",
    hashrate: "1.0 kH/s",
    rigforge: null,
    writable_keys: ["DONATION"],
    last_applied: {},
    history: [],
    hashrate_history: { hashrate: [], markers: [] },
    editable: false,
    control_enabled: true,
    ip: "10.0.0.9",
    ...extra,
  };
  inst.state = { ...inst.state, phase: "ready", detail, editText: "{}" };
  return renderToString(inst.render());
}

test("Worker Inspect: the adopt form receives the detail's rig_id and shows its field", () => {
  assert.match(adoptRender({ rig_id: RIG_ID }), new RegExp(`value="${RIG_ID}"`));
});

test("Worker Inspect: no rig_id in the detail hides the adopt form's rig_id field", () => {
  assert.doesNotMatch(adoptRender({ rig_id: null }), /placeholder="the rig's identity id/);
});
