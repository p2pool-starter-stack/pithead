import assert from "node:assert/strict";
import { createServer } from "node:http";
import { connect } from "node:net";
import { test } from "node:test";
import { stopFixture } from "./stop-fixture.mjs";

test("fixture teardown completes while a connection holds a half-sent request", {
  timeout: 10000,
}, async () => {
  const server = createServer((req, res) => res.end("ok"));
  await new Promise((r) => server.listen(0, "127.0.0.1", r));
  const socket = connect(server.address().port, "127.0.0.1");
  socket.on("error", () => {});
  await new Promise((r) => socket.on("connect", r));
  socket.write("GET / HTTP/1.1\r\nHost: fixture\r\n");
  await new Promise((r) => setTimeout(r, 100));
  let closed = false;
  const closing = stopFixture(server).then(() => { closed = true; });
  await Promise.race([closing, new Promise((r) => setTimeout(r, 3000))]);
  socket.destroy();
  assert.equal(closed, true);
});
