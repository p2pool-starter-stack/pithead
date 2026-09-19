// Shared modal dialog (#1876). The render harness is DOM-less, so the lifecycle that matters here
// — closing an open <dialog> when the PARENT drops it (a commit lands, a backup finishes) rather
// than cancelling it — is driven directly against a fake dialog element. Unmounting an open
// dialog without close() skips the spec's close-the-dialog steps, and focus-return lives there.
import assert from "node:assert/strict";
import { test } from "node:test";

import { Modal } from "../../../mining_dashboard/web/static/app/modal.mjs";
import { renderToString } from "../helpers/render.mjs";

function mounted(props = {}) {
  const inst = new Modal(props);
  inst.props = props;
  const calls = { close: 0 };
  inst.dialogRef.current = {
    close: () => {
      calls.close++;
    },
  };
  return { inst, calls };
}

test("a parent dropping the modal still closes the dialog, so focus returns to the opener", () => {
  const { inst, calls } = mounted({ title: "Review changes" });
  inst.componentWillUnmount();
  assert.equal(calls.close, 1);
});

test("the unmount close does not fire onClose, which would re-phase a still-mounted parent", () => {
  let closed = 0;
  const { inst } = mounted({ title: "Review changes", onClose: () => closed++ });
  inst.componentWillUnmount();
  // ConfigView's onClose sends it back to "form"; commit() has already set "done". Firing it here
  // would bounce the operator off the result they just produced.
  const handler = inst.render().props.onClose;
  handler({});
  assert.equal(closed, 0);
});

test("a normal close still reaches onClose, so the parent can drop the modal", () => {
  let closed = 0;
  const { inst } = mounted({ title: "Review changes", onClose: () => closed++ });
  inst.render().props.onClose({});
  assert.equal(closed, 1);
});

test("Escape is refused by default so a caller can keep an in-flight modal open", () => {
  let cancelled = 0;
  let prevented = 0;
  const { inst } = mounted({ title: "Creating a backup…", onCancel: () => cancelled++ });
  inst.render().props.onCancel({ preventDefault: () => prevented++ });
  assert.equal(prevented, 1); // never the browser's own close — the caller decides
  assert.equal(cancelled, 1);
});

test("the dialog carries its role, modal flag and name", () => {
  const out = renderToString({ type: Modal, props: { title: "Create a backup" } });
  assert.match(out, /^\s*<dialog class="card config-modal"/);
  assert.match(out, /role="dialog"/);
  assert.match(out, /aria-modal="true"/);
  assert.match(out, /aria-label="Create a backup"/);
  assert.match(out, /<h3 tabindex="-1">Create a backup<\/h3>/); // focus target on open
});
