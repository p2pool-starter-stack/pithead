import assert from "node:assert/strict";
import { test } from "node:test";
import { Modal } from "../../../mining_dashboard/web/static/app/modal.mjs";
import { OsUpdateControl } from "../../../mining_dashboard/web/static/system/osupdate.mjs";
import { renderToString } from "../helpers/render.mjs";

function find(node, predicate) {
  if (Array.isArray(node)) return node.map((n) => find(n, predicate)).find(Boolean);
  if (!node || typeof node !== "object") return null;
  return predicate(node) ? node : find(node.props?.children, predicate);
}

test("an update-check error Close closes the native dialog once and dismisses the modal", async () => {
  const control = new OsUpdateControl({ os: { step: "idle" }, enabled: true });
  control.setState = (patch) => Object.assign(control.state, patch);
  find(control.render(), (n) => n.type === "button").props.onClick();
  const originalFetch = globalThis.fetch;
  const originalTimeout = globalThis.setTimeout;
  try {
    globalThis.setTimeout = (cb) => { cb(); return 0; };
    globalThis.fetch = async (_, opts) => ({
      ok: true,
      json: async () => opts?.method === "POST" ? { id: "fixture-check" } : {
        status: "failed", error: "the latest release publishes no appliance OS bundle",
      },
    });
    await control.check();
  } finally {
    globalThis.fetch = originalFetch;
    globalThis.setTimeout = originalTimeout;
  }
  assert.equal(control.state.phase, "error");
  assert.match(renderToString(control.render()), /publishes no appliance OS bundle/);
  const modalNode = find(control.render(), (n) => n.type === Modal);
  const modal = new Modal(modalNode.props);
  control.modalRef.current = modal;
  let closes = 0;
  modal.dialogRef.current = {
    // Native close runs the focus-return steps; real browser focus is checked in manual QA.
    close() { closes++; modal.render().props.onClose({}); },
  };
  const button = find(control.renderBody(), (n) => n.type === "button" && n.props.children === "Close");
  assert.ok(button);
  button.props.onClick();
  assert.equal(closes, 1);
  assert.equal(control.state.phase, "closed");
  assert.equal(find(control.render(), (n) => n.type === Modal), undefined);
});
