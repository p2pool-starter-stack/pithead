import { test } from "node:test";
import assert from "node:assert/strict";
import { ConfigView } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { PreviewModal, runUpgrade, UpgradeControl } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { renderToString } from "../helpers/render.mjs";

const ID = "11111111-1111-4111-8111-111111111111";

const okResult = (body) => ({ status: 200, ok: true, json: async () => body });

// Drive poll() with setTimeout fired synchronously so the 2s cadence doesn't slow the test,
// restoring the globals afterwards.
async function withFastPoll(fetchStub, fn) {
  const realFetch = globalThis.fetch;
  const realTimeout = globalThis.setTimeout;
  globalThis.fetch = fetchStub;
  globalThis.setTimeout = (cb) => {
    cb();
    return 0;
  };
  try {
    return await fn();
  } finally {
    globalThis.fetch = realFetch;
    globalThis.setTimeout = realTimeout;
  }
}

const UPDATE = { available: true, latest: "v9.9.9", url: "https://example.invalid/rel" };

// --- Confirm-gated disruptive change in the modal (#719) --------------------------------------
//
// An in-scope disruptive change previews as destructive (a CONFIRM row). The modal must warn (⚠),
// show the type-APPLY box, and keep Confirm disabled until the operator types the literal APPLY.
const CONFIRM_PREVIEW = {
  changes: [
    { flag: "CONFIRM", key: "monero.clearnet_initial_sync", msg: "Clearnet initial sync ENABLED — host IP exposed during IBD." },
  ],
  destructive: true,
};

test("poll rides out a transient fetch failure (container recreate) then returns the result", async () => {
  let calls = 0;
  const fetchStub = async () => {
    calls++;
    if (calls === 1) throw new TypeError("Failed to fetch"); // dashboard restarting mid-apply
    return okResult({ status: "applied" });
  };
  const view = new ConfigView({});
  const out = await withFastPoll(fetchStub, () => view.poll(ID));
  assert.equal(out.status, "applied");
  assert.equal(calls, 2); // it retried after the throw instead of surfacing an error
});

test("poll skips the still-present preview result until the commit outcome lands", async () => {
  let calls = 0;
  const fetchStub = async () => {
    calls++;
    return okResult(calls < 2 ? { status: "previewed" } : { status: "applied" });
  };
  const view = new ConfigView({});
  const out = await withFastPoll(fetchStub, () => view.poll(ID, "previewed"));
  assert.equal(out.status, "applied");
});

test("runUpgrade posts the seen version, skips 'running', rides out the restart, returns the outcome", async () => {
  let posted = null;
  let polls = 0;
  const fetchStub = async (url, opts) => {
    if (url === "/api/control/upgrade") {
      posted = { body: JSON.parse(opts.body), headers: opts.headers };
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    polls++;
    if (polls === 1) return okResult({ status: "running", version: "v9.9.9" });
    if (polls === 2) throw new TypeError("Failed to fetch"); // dashboard recreated mid-upgrade
    return okResult({ status: "upgraded", version: "v9.9.9" });
  };
  const out = await withFastPoll(fetchStub, () => runUpgrade("v9.9.9"));
  assert.equal(out.status, "upgraded");
  assert.deepEqual(posted.body, { version: "v9.9.9" }); // the proposal — nothing else crosses
  assert.equal(posted.headers["X-Pithead-Control"], "1"); // CSRF guard rides every mutation
});

test("runUpgrade rides out a 502/503/504 from the proxy (upstream mid-restart), not just a dropped connection (#622)", async () => {
  let polls = 0;
  const fetchStub = async (url) => {
    if (url === "/api/control/upgrade") {
      return { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) };
    }
    polls++;
    // caddy stays up and answers a gateway error while the dashboard upstream is recreated —
    // the common self-upgrade state, and the one the old poller misclassified as terminal.
    if (polls <= 3) return { status: 502, ok: false, json: async () => ({}) };
    return okResult({ status: "upgraded", version: "v9.9.9" });
  };
  const out = await withFastPoll(fetchStub, () => runUpgrade("v9.9.9"));
  assert.equal(out.status, "upgraded"); // rode out the 502s to the durable result, no throw
});

test("runUpgrade surfaces a host-side rejection as the outcome, not a throw", async () => {
  const fetchStub = async (url) =>
    url === "/api/control/upgrade"
      ? { status: 202, ok: false, json: async () => ({ id: ID, status: "pending" }) }
      : okResult({ status: "rejected", error: "already up to date" });
  const out = await withFastPoll(fetchStub, () => runUpgrade("v9.9.9"));
  assert.equal(out.status, "rejected");
  assert.match(out.error, /up to date/);
});

test("UpgradeControl renders nothing without a newer release or with the channel off", () => {
  const inst = (props) => {
    const c = new UpgradeControl(props);
    c.props = props;
    return renderToString(c.render());
  };
  assert.equal(inst({ update: null, enabled: true }), "");
  assert.equal(inst({ update: { available: false }, enabled: true }), "");
  assert.equal(inst({ update: UPDATE, enabled: false }), "");
  assert.match(inst({ update: UPDATE, enabled: true }), /Upgrade to v9\.9\.9/);
});

test("the confirm modal arms only on a typed UPGRADE", () => {
  const props = { update: UPDATE, enabled: true };
  const inst = new UpgradeControl(props);
  inst.props = props;
  inst.state.phase = "confirm";
  assert.match(renderToString(inst.render()), /disabled/); // unarmed until typed
  inst.state.confirmText = "UPGRADE";
  assert.doesNotMatch(renderToString(inst.render()), /disabled/);
});

// #637: the host names the restore point in the result — the done modal shows the fresh-dir
// rollback copy, the failed modal shows the in-place pre-upgrade config/.env copies. A result
// without the field (an in-place success, an old runner) renders neither sentence.
test("the done modal names the rollback dir when the result carries one (#637)", () => {
  const props = { update: UPDATE, enabled: true };
  const inst = new UpgradeControl(props);
  inst.props = props;
  inst.state.phase = "done";
  inst.state.result = { status: "upgraded", version: "v9.9.9", rollback: "/srv/pithead-v1.3.1" };
  assert.match(renderToString(inst.render()), /\/srv\/pithead-v1\.3\.1/);
  inst.state.result = { status: "upgraded", version: "v9.9.9" };
  assert.doesNotMatch(renderToString(inst.render()), /rollback copy/);
});

test("the failed modal names the pre-upgrade config/.env copies when the result carries them (#637)", () => {
  const props = { update: UPDATE, enabled: true };
  const inst = new UpgradeControl(props);
  inst.props = props;
  inst.state.phase = "failed";
  inst.state.result = { status: "failed", error: "boom", backup: "/x/config.json.bak-upgrade-1 /x/.env.bak-upgrade-1" };
  assert.match(renderToString(inst.render()), /bak-upgrade-1/);
  inst.state.result = { status: "failed", error: "boom" };
  assert.doesNotMatch(renderToString(inst.render()), /Pre-upgrade copies/);
});

// --- Preview modal (#504) --------------------------------------------------------------
//
// dashboard.energy is config.json-only, so the host runner previews an energy edit as a normal
// INFO change row (not the old, non-committable HOST note). The modal must render it as a pending
// change and arm Confirm — a non-destructive change needs no typed APPLY.
test("an INFO change (e.g. dashboard.energy) renders committable and arms Confirm", () => {
  const preview = {
    changes: [{ flag: "INFO", key: "dashboard.energy", msg: "Energy calculator settings updated." }],
    destructive: false,
  };
  const out = renderToString(PreviewModal({ preview, confirmText: "", busy: false }));
  assert.match(out, /Energy calculator settings updated\./); // the change is shown
  assert.doesNotMatch(out, /No configuration changes detected/);
  // Confirm is armed: the only disabled control is absent for a non-destructive, non-empty change.
  assert.doesNotMatch(out, /disabled/);
});

test("an empty preview leaves Confirm disabled", () => {
  const out = renderToString(
    PreviewModal({ preview: { changes: [], destructive: false }, confirmText: "", busy: false }),
  );
  assert.match(out, /No configuration changes detected/);
  assert.match(out, /disabled/); // nothing to commit
});

test("a CONFIRM change warns and gates Confirm behind the typed APPLY (#719)", () => {
  const notYet = renderToString(
    PreviewModal({ preview: CONFIRM_PREVIEW, confirmText: "", busy: false }),
  );
  assert.match(notYet, /⚠/); // the disruptive row is warned
  assert.match(notYet, /host IP exposed during IBD/);
  assert.match(notYet, /Type <code>APPLY<\/code> to confirm/); // the type-to-confirm box is shown
  // Confirm is still disabled — the confirm-apply button carries `disabled` until APPLY is typed.
  const btnNotYet = notYet.match(/<button class="btn-toggle active"[^>]*>/)[0];
  assert.match(btnNotYet, /disabled/);
});

test("a CONFIRM change arms Confirm once APPLY is typed (#719)", () => {
  const armed = renderToString(
    PreviewModal({ preview: CONFIRM_PREVIEW, confirmText: "APPLY", busy: false }),
  );
  const btnArmed = armed.match(/<button class="btn-toggle active"[^>]*>/)[0];
  assert.doesNotMatch(btnArmed, /disabled/); // now committable
});
