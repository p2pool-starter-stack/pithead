import assert from "node:assert/strict";
import { test } from "node:test";
import { parseConfigDocument } from "../../../mining_dashboard/web/static/config/jsondocument.mjs";

for (const text of [
  '{"a":{"x":1},"b":{"x":2}}',
  '{"a":[{},[],null,true,false,1,-1.5e2,"quotes \\\" and \\\\ braces {} : []"]}',
  '{"a":{},"b":[]}',
  '{"__proto__":{"a":1}}',
  '{}',
]) {
  test(`ordinary JSON is unchanged: ${text}`, () => {
    assert.deepEqual(parseConfigDocument(text), JSON.parse(text));
  });
}

test("duplicate empty blocks with different members are refused", () => {
  assert.throws(() => parseConfigDocument('{"a":{"x":1},"a":{"y":2}}'), /duplicate key "a"/);
  assert.throws(() => parseConfigDocument('{"a":null,"a":false}'), /duplicate key "a"/);
});

test("malformed JSON uses the existing operator message", () => {
  assert.throws(() => parseConfigDocument('{"a":}'), /Not valid JSON/);
});
