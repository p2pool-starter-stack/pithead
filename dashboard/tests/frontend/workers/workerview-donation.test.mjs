import assert from "node:assert/strict";
import { test } from "node:test";
import { renderToString } from "../helpers/render.mjs";
import { readyInstance } from "./workerview-helpers.mjs";

test("the editor says a DONATION below the miner's built-in minimum has no effect", () => {
  const out = renderToString(readyInstance().render());
  assert.match(out, /below the rig's built-in minimum has no effect/);
  assert.match(out, /donating at least 1%/);
});
