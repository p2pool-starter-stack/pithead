import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import test from "node:test";
import vm from "node:vm";

const SCRIPT = new URL("../../../mining_dashboard/web/static/login.js", import.meta.url);

function load(fetchImpl) {
  const page = { hidden: true, textContent: "", submit: null, assigned: "" };
  const form = {
    username: { value: "admin" },
    password: { value: "hunter2" },
    remember: { checked: false },
    querySelector: () => ({ disabled: false }),
    addEventListener(_event, handler) {
      page.submit = handler;
    },
  };
  const errorBox = { hidden: true, textContent: "" };
  const context = vm.createContext({
    document: { getElementById: (id) => (id === "login-form" ? form : errorBox) },
    fetch: fetchImpl,
    location: {
      assign(url) {
        page.assigned = url;
      },
    },
  });
  vm.runInContext(readFileSync(SCRIPT, "utf8"), context);
  page.box = errorBox;
  return page;
}

test("a sign-in storage failure shows the server's disk-full message", async () => {
  const page = load(async () => ({
    ok: false,
    status: 503,
    json: async () => ({ error: "The data disk is full, so sign-in cannot save your session." }),
  }));
  await page.submit({ preventDefault() {} });
  assert.match(page.box.textContent, /disk is full/);
  assert.equal(page.box.hidden, false);
  assert.equal(page.assigned, "");
});

test("a non-JSON failure still shows the generic sign-in message", async () => {
  const page = load(async () => ({
    ok: false,
    status: 503,
    json: async () => {
      throw new SyntaxError("Unexpected token <");
    },
  }));
  await page.submit({ preventDefault() {} });
  assert.match(page.box.textContent, /unavailable right now/);
});

test("wrong credentials still show the fixed wrong-password message", async () => {
  const page = load(async () => ({
    ok: false,
    status: 401,
    json: async () => ({ error: "Invalid username or password." }),
  }));
  await page.submit({ preventDefault() {} });
  assert.equal(page.box.textContent, "Wrong username or password.");
});
