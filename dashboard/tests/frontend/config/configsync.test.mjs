// Unit tests for the shared form ⇄ JSON sync logic:
// mining_dashboard/web/static/config/configsync.mjs — dotted-path access, reference-typed coercion,
// and the live guidance the wizard gives on pasted material. Pure functions, no DOM.
//
// Run with Node's built-in test runner (CI runs exactly this):
//     node --test dashboard/tests/frontend/
import assert from "node:assert/strict";
import { test } from "node:test";

import {
  classifyMoneroAddress,
  coerceForPath,
  pathGet,
  pathSet,
  telegramPairReady,
} from "../../../mining_dashboard/web/static/config/configsync.mjs";

test("pathGet reads nested dotted paths and tolerates absent branches", () => {
  const obj = { monero: { remote: { host: "bench-node" } } };
  assert.equal(pathGet(obj, "monero.remote.host"), "bench-node");
  assert.equal(pathGet(obj, "monero.remote.rpc_port"), undefined);
  assert.equal(pathGet(obj, "tari.mode"), undefined);
  assert.equal(pathGet({}, "a.b.c"), undefined);
});

test("pathSet creates intermediate objects and overwrites scalars in the way", () => {
  const obj = {};
  pathSet(obj, "monero.remote.host", "bench-node");
  assert.deepEqual(obj, { monero: { remote: { host: "bench-node" } } });
  // A scalar sitting where an object is needed must not crash the edit.
  const scalar = { monero: "oops" };
  pathSet(scalar, "monero.mode", "remote");
  assert.deepEqual(scalar, { monero: { mode: "remote" } });
});

test("coerceForPath keeps the reference's types — ports stay numbers, toggles booleans", () => {
  const ref = { monero: { remote: { rpc_port: 18081 }, prune: true }, tari: { mode: "local" } };
  assert.equal(coerceForPath(ref, "monero.remote.rpc_port", "18089"), 18089);
  assert.equal(coerceForPath(ref, "monero.prune", "false"), false);
  assert.equal(coerceForPath(ref, "monero.prune", "true"), true);
  // A numeric-looking string stays a string when the reference holds a string there.
  assert.equal(coerceForPath(ref, "tari.mode", "12345"), "12345");
  // Unknown paths keep the raw string — the host validates meaning.
  assert.equal(coerceForPath(ref, "no.such.key", "18089"), "18089");
});

test("classifyMoneroAddress names the actual mistake", () => {
  assert.equal(classifyMoneroAddress("").kind, "empty");
  assert.equal(classifyMoneroAddress(`8${"A".repeat(94)}`).kind, "subaddress");
  assert.equal(classifyMoneroAddress(`4${"A".repeat(105)}`).kind, "integrated");
  assert.equal(classifyMoneroAddress(`9${"A".repeat(94)}`).kind, "not-primary");
  assert.equal(classifyMoneroAddress("4ABC").kind, "partial");
  assert.equal(classifyMoneroAddress(`4${"A".repeat(94)}`).kind, "ok");
});

test("telegramPairReady demands both halves or neither", () => {
  assert.deepEqual(telegramPairReady("123:ABC", "999"), { ready: true, partial: false });
  assert.deepEqual(telegramPairReady("123:ABC", ""), { ready: false, partial: true });
  assert.deepEqual(telegramPairReady("", "999"), { ready: false, partial: true });
  assert.deepEqual(telegramPairReady("", ""), { ready: false, partial: false });
});

test("coerceForType follows the field's declared type", async () => {
  const { coerceForType } = await import("../../../mining_dashboard/web/static/config/configsync.mjs");
  assert.equal(coerceForType("boolean", "true"), true);
  assert.equal(coerceForType("boolean", "false"), false);
  assert.equal(coerceForType("number", "18081"), 18081);
  assert.equal(coerceForType("number", "0.5"), 0.5);
  // Garbage stays a string for the host validator to name, never NaN into the config.
  assert.equal(coerceForType("number", "not-a-port"), "not-a-port");
  assert.equal(coerceForType("number", ""), "", "an empty field is not zero (#3350)");
  assert.equal(coerceForType("number", " "), " ");
  assert.equal(coerceForType("text", "18081"), "18081");
});

test("focusSection opens and focuses only the named section, once per shortcut (#3359)", async () => {
  const { focusSection } = await import("../../../mining_dashboard/web/static/config/configsync.mjs");
  const make = () => {
    const summary = { calls: [], scrollIntoView() {}, focus() { this.calls.push("focus"); } };
    return { open: false, summary, querySelector: () => summary };
  };
  const payouts = make();
  const node = make();
  const focus = { section: "Payouts" };
  focusSection(node, "Monero node", focus);
  assert.equal(node.open, false);
  focusSection(payouts, "Payouts", focus);
  assert.equal(payouts.open, true);
  assert.deepEqual(payouts.summary.calls, ["focus"]);
  // A re-render with the same shortcut must not reopen a section the operator collapsed.
  payouts.open = false;
  focusSection(payouts, "Payouts", focus);
  assert.equal(payouts.open, false);
  // A fresh click is a fresh object, so it fires again; no shortcut is a no-op.
  focusSection(payouts, "Payouts", { section: "Payouts" });
  assert.equal(payouts.open, true);
  focusSection(payouts, "Payouts", undefined);
});
