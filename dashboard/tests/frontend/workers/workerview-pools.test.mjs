import assert from "node:assert/strict";
import { test } from "node:test";
import { renderToString } from "../helpers/render.mjs";
import { DETAIL, readyInstance } from "./workerview-helpers.mjs";

const CONFIRM_PROMPT = /Type <code>APPLY<\/code> to change this rig's pools/;

function captureApplies() {
  const posted = [];
  const realFetch = globalThis.fetch;
  globalThis.fetch = async (_url, opts) => {
    posted.push(JSON.parse(opts.body));
    return { json: async () => ({ status: "applied" }) };
  };
  return { posted, restore: () => (globalThis.fetch = realFetch) };
}

test("a pools change is held until APPLY is typed, then sent with the confirmation", async () => {
  const inst = readyInstance({ ...DETAIL, writable_keys: [...DETAIL.writable_keys, "pools"] });
  inst.state.mode = "json";
  inst.onJsonInput(JSON.stringify({ pools: [{ url: "pool.example:3333" }] }));
  assert.doesNotMatch(renderToString(inst.render()), CONFIRM_PROMPT);
  const { posted, restore } = captureApplies();
  try {
    await inst.apply();
    assert.equal(posted.length, 0);
    assert.match(renderToString(inst.render()), CONFIRM_PROMPT);
    inst.state.poolsConfirm = "apply";
    await inst.apply();
    assert.equal(posted.length, 0);
    assert.match(renderToString(inst.render()), CONFIRM_PROMPT);
    inst.state.poolsConfirm = "APPLY";
    await inst.apply();
  } finally {
    restore();
  }
  assert.equal(posted.length, 1);
  assert.equal(posted[0].confirm, "APPLY");
  assert.deepEqual(posted[0].changes, { pools: [{ url: "pool.example:3333" }] });
  assert.doesNotMatch(renderToString(inst.render()), CONFIRM_PROMPT);
});

test("a typed APPLY does not carry past a failed send: the next pools change is held again", async () => {
  const inst = readyInstance({ ...DETAIL, writable_keys: [...DETAIL.writable_keys, "pools"] });
  inst.state.mode = "json";
  inst.onJsonInput(JSON.stringify({ pools: [{ url: "pool.example:3333" }] }));
  const realFetch = globalThis.fetch;
  let sends = 0;
  globalThis.fetch = async () => {
    sends += 1;
    throw new Error("network down");
  };
  try {
    await inst.apply();
    inst.state.poolsConfirm = "APPLY";
    await inst.apply();
    assert.equal(sends, 1);
    assert.match(inst.state.result.error, /network down/);
    await inst.apply();
  } finally {
    globalThis.fetch = realFetch;
  }
  assert.equal(sends, 1);
  assert.equal(inst.state.poolsConfirm, "");
  assert.match(renderToString(inst.render()), CONFIRM_PROMPT);
});

test("a change without pools sends no confirmation field", async () => {
  const inst = readyInstance();
  inst.state.tableEdits = { DONATION: "6" };
  const { posted, restore } = captureApplies();
  try {
    await inst.apply();
  } finally {
    restore();
  }
  assert.equal(posted.length, 1);
  assert.ok(!("confirm" in posted[0]));
});
