// Fixture teardown shared by the browser tests. Chromium closes first: its speculative
// connections (a request started but never finished) are neither idle nor active, so a bare
// server.close() waits on them forever and the browser is never closed, stalling the whole
// file until the Actions job maximum (#3292).
export async function stopFixture(server, browser) {
  await browser?.close();
  server.closeAllConnections();
  await new Promise((r) => server.close(r));
}
