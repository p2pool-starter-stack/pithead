import { test } from "node:test";
import assert from "node:assert/strict";

import {
  ConfigView,
  PreviewModal,
} from "../../../mining_dashboard/web/static/config/configview.mjs";
import { buildSections } from "../../../mining_dashboard/web/static/config/configlogic.mjs";
import { renderToString } from "../helpers/render.mjs";

test("sensitive payout preview shows full values and requires the destination suffix", () => {
  const preview = {
    changes: [{ flag: "DEST", key: "MONERO_WALLET_ADDRESS", msg: "Payout changes." }],
    destructive: true,
    approval_required: true,
    preview_values: [
      { label: "Monero payout", old: "4old-address-full", new: "4new-address-full" },
    ],
    payout_confirmations: { monero: "ress-full" },
  };
  const unarmed = renderToString(
    PreviewModal({ preview, confirmText: "APPLY", payoutSuffixes: { monero: "wrong" }, busy: false }),
  );
  assert.match(unarmed, /4old-address-full/);
  assert.match(unarmed, /4new-address-full/);
  assert.match(unarmed, /allow-listed Telegram account/);
  assert.match(unarmed.match(/<button class="btn-toggle active"[^>]*>/)[0], /disabled/);
  const armed = renderToString(
    PreviewModal({
      preview,
      confirmText: "APPLY",
      payoutSuffixes: { monero: "ress-full" },
      busy: false,
    }),
  );
  assert.doesNotMatch(armed.match(/<button class="btn-toggle active"[^>]*>/)[0], /disabled/);
});

test("default and failed-apply labels distinguish desired configuration from running state", () => {
  const cfg = { xvb: { enabled: true } };
  const inst = new ConfigView({});
  const text = JSON.stringify(cfg, null, 2);
  inst.state = {
    ...inst.state,
    phase: "form",
    cfg,
    sections: buildSections(cfg),
    coreKeys: [],
    candidate: cfg,
    pristine: text,
    editText: text,
    editableKeys: ["xvb.enabled"],
    defaultKeys: ["xvb.enabled"],
    lastApply: { status: "failed", id: "11111111-1111-4111-8111-111111111111" },
  };
  const out = renderToString(inst.render());
  assert.match(out, /enabled \(default\)/);
  assert.match(out, /desired configuration/);
  assert.match(out, /may still use the earlier settings/);
  assert.match(out, /A few developer settings are not shown here/);
  assert.doesNotMatch(out, /host's gate|authority on what commits/);
});
