import assert from "node:assert/strict";
import { test } from "node:test";
import { renderToString } from "../helpers/render.mjs";
import { readyInstance } from "./workerview-helpers.mjs";

test("the editor says appliance rigs honour any DONATION from 0 and shows the configured value", () => {
  const out = renderToString(readyInstance().render());
  assert.match(out, /honour any <span class="font-mono">DONATION<\/span> from 0 to 100/);
  assert.match(out, /configured, not the rate the miner runs/);
  assert.doesNotMatch(out, /built-in minimum/);
  assert.doesNotMatch(out, /at least 1%/);
});
