import { html } from "../app/preact.mjs";

export const POOLS_HELD = {
  status: "error",
  error: "This changes the rig's pools. Type APPLY to confirm.",
};

export const POOLS_HOLD = { result: POOLS_HELD, poolsConfirm: "" };

export const poolsHeld = (changes, { result, poolsConfirm }) =>
  "pools" in changes && !(result === POOLS_HELD && poolsConfirm === "APPLY");

export const applyRequest = (worker, changes) =>
  "pools" in changes ? { worker, changes, confirm: "APPLY" } : { worker, changes };

export function PoolsConfirm({ view }) {
  const { poolsConfirm, result } = view.state;
  if (result !== POOLS_HELD) return null;
  return html`<label class="config-confirm-type">Type <code>APPLY</code> to change this rig's pools:
    <input type="text" autocomplete="off" spellcheck="false" value=${poolsConfirm}
           onInput=${(e) => view.setState({ poolsConfirm: e.target.value })} /></label>`;
}
