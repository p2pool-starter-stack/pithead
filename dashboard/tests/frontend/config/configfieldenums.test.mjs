// The frontend's fixed-choice field enums vs. the HOST parser that actually rejects a bad config
// (#1929). FIELD_OPTIONS in config/configlogic.mjs is a hand-kept copy of an enum owned by
// lib/pithead/28-parse-and-validate-config.sh; this file is the only thing that compares them.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

import { buildSections } from "../../../mining_dashboard/web/static/config/configlogic.mjs";

// #1929. The defect was one missing enum value, but the CLASS is drift: FIELD_OPTIONS is a
// hand-kept copy of an enum the HOST parser owns, and a copy that nobody compares rots silently —
// an off machine rendered `value:"off"` against `options:["local","remote"]`, a select matching
// none of its own options, so the Configuration view showed "local" for a machine with Tari off.
//
// So this does NOT assert a list (a guard written from the same list it guards is green by
// construction). It reads the allowed values out of the shell validator that actually rejects a
// bad config and compares. A future `tari.mode: "auto"` added host-side reds HERE.
test("a mode select offers exactly what the host parser accepts (#1929)", () => {
  const sh = readFileSync(
    new URL("../../../../lib/pithead/28-parse-and-validate-config.sh", import.meta.url),
    "utf8",
  );
  for (const [key, envVar] of [
    ["tari.mode", "TARI_MODE"],
    ["monero.mode", "MONERO_MODE"],
  ]) {
    const m = sh.match(new RegExp(`case "\\$${envVar}" in\\s*\\n\\s*([a-z |]+)\\)`));
    assert.ok(m, `no \`case "$${envVar}" in\` validator found — the needle, not the code, moved`);
    const allowed = m[1].split("|").map((s) => s.trim());
    // A regex that matched something useless is not evidence: every validator here is a real
    // multi-value enum, so a 1-element read means the capture drifted, not that the enum shrank.
    assert.ok(allowed.length >= 2, `${envVar}: parsed a degenerate enum ${JSON.stringify(allowed)}`);
    const [chain, leaf] = key.split(".");
    const field = buildSections({ [chain]: { [leaf]: allowed[0] } })
      .flatMap((s) => s.fields)
      .find((f) => f.key === key);
    assert.deepEqual([...field.options].sort(), [...allowed].sort(), `${key} options`);
    // The #1929 defect itself, stated as the property it violated: whatever the host accepts, the
    // rendered select can express — so the view never reports a state the machine is not in.
    for (const value of allowed) {
      const f = buildSections({ [chain]: { [leaf]: value } })
        .flatMap((s) => s.fields)
        .find((x) => x.key === key);
      assert.ok(f.options.includes(f.value), `${key}="${value}" matches none of its own options`);
    }
  }
});
