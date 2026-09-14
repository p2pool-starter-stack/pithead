import assert from "node:assert/strict";
import { test } from "node:test";

import { Header } from "../../../mining_dashboard/web/static/app/header.mjs";
import { UpgradeControl } from "../../../mining_dashboard/web/static/config/configview.mjs";
import { clone } from "../harness.mjs";
import { renderToString } from "../helpers/render.mjs";

function find(vnode, type) {
  if (!vnode) return null;
  if (Array.isArray(vnode)) return vnode.map((v) => find(v, type)).find(Boolean) || null;
  if (vnode.type === type) return vnode;
  return find(vnode.props?.children, type);
}

test("Header keeps an appliance upgrade failure honest without enabling tarball upgrades", () => {
  const state = clone();
  state.os_update = { step: "idle" };
  const mounted = find(Header({ state }), UpgradeControl);
  assert.equal(mounted.props.appliance, true);
  assert.equal(mounted.props.enabled, false);

  const control = new UpgradeControl(mounted.props);
  control.state = {
    phase: "failed",
    confirmText: "",
    result: {
      log: "Run './pithead upgrade' after fixing the service",
      recovery: "cd /srv/pithead && ./pithead upgrade",
      backup: "/srv/pithead/config.json.bak-upgrade-1 /srv/pithead/.env.bak-upgrade-1",
    },
  };
  const out = renderToString(control.render());
  assert.match(out, /this machine's own log from the failed upgrade/);
  assert.match(out, /kept on this machine/);
  assert.doesNotMatch(out, /cd \/srv|kept on the host|\.bak-upgrade/);
});
