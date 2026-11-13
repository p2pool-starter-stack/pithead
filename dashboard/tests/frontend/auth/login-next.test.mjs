import assert from "node:assert/strict";
import { test } from "node:test";

import { safeNext } from "../../../mining_dashboard/web/static/login-next.mjs";

test("a same-site path is kept, with its query", () => {
  assert.equal(safeNext("?next=%2Fconfig%3Fa%3D1"), "/config?a=1");
  assert.equal(safeNext("?next=/config?a%3D1"), "/config?a=1");
});

test("no next goes to the dashboard", () => {
  assert.equal(safeNext(""), "/");
  assert.equal(safeNext("?next="), "/");
});

test("an off-site or scheme-relative target is refused", () => {
  for (const next of [
    "https://evil.example/",
    "//evil.example/",
    "/\\evil.example",
    "javascript:alert(1)",
    "evil",
  ]) {
    assert.equal(safeNext(`?next=${encodeURIComponent(next)}`), "/", next);
  }
});
