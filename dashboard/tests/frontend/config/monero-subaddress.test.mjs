import assert from "node:assert/strict";
import { test } from "node:test";

import { buildSections } from "../../../mining_dashboard/web/static/config/configlogic.mjs";
import { classifyMoneroSubaddress } from "../../../mining_dashboard/web/static/config/configsync.mjs";
import { PreviewModal } from "../../../mining_dashboard/web/static/config/configpreview.mjs";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { renderToString } from "../helpers/render.mjs";

test("optional Monero subaddress accepts blank or an exact 8-prefixed address", () => {
  assert.equal(classifyMoneroSubaddress("").kind, "empty");
  assert.equal(classifyMoneroSubaddress(`8${"A".repeat(94)}`).kind, "ok");
  assert.equal(classifyMoneroSubaddress(`4${"A".repeat(94)}`).kind, "not-subaddress");
  assert.equal(classifyMoneroSubaddress(`8${"A".repeat(93)}`).kind, "partial");
  assert.equal(classifyMoneroSubaddress(42).kind, "not-subaddress");
});

test("subaddress renders in Payouts with a payout-change warning", () => {
  const payouts = buildSections({
    monero: { wallet_address: `4${"A".repeat(94)}`, subaddress: "" },
  }).find((section) => section.name === "Payouts");
  const field = payouts.fields.find((candidate) => candidate.key === "monero.subaddress");
  assert.ok(field);
  assert.match(field.warning, /payout/);
});

test("subaddress approval names the Monero subaddress destination", () => {
  const out = renderToString(
    PreviewModal({
      preview: {
        changes: [{ flag: "DEST", msg: "change" }],
        approval_required: true,
        payout_confirmations: { monero_subaddress: "suffix" },
      },
      payoutSuffixes: {},
      onPayoutSuffix() {},
      onConfirm() {},
      onCancel() {},
      onClose() {},
    }),
  );
  assert.match(out, /new Monero subaddress/);
});

test("configuration editor marks an invalid subaddress and blocks Save", () => {
  const cfg = { monero: { subaddress: `8${"A".repeat(93)}` } };
  const view = new ConfigView({});
  view.state = {
    ...view.state,
    phase: "form",
    cfg,
    sections: buildSections(cfg),
    candidate: structuredClone(cfg),
    pristine: JSON.stringify({ monero: { subaddress: "" } }),
    editText: JSON.stringify(cfg),
    editableKeys: ["monero.subaddress"],
  };
  const out = renderToString(view.render());
  assert.match(out, /aria-invalid="true"/);
  assert.match(out, /94 of 95 characters/);
  assert.match(out, /disabled[^>]*>Save & preview changes/);
});
