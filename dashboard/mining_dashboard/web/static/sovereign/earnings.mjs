import { html } from "../app/preact.mjs";
import { fleetLine } from "./donation-model.mjs";
import { EarningsControl } from "./earnings-control.mjs";
import { ESTIMATES_PENDING, payoutRows, trackingNotice, xvbLine } from "./earnings-model.mjs";

export function EarningsPage({
  state,
  connected = true,
  sessionExpired = false,
  url,
  onDirtyChange,
}) {
  if (!state) return html`<p class="panel" role="status">Waiting for earnings data…</p>`;
  const link = new URL(url);
  link.searchParams.set("page", "earnings");
  link.searchParams.set("advanced", "payout");
  const machinesLink = new URL(url);
  machinesLink.searchParams.set("page", "machines");
  machinesLink.searchParams.delete("advanced");
  const rows = payoutRows(state);
  const summary = state.earnings?.confirmed;
  const notice = trackingNotice(summary);
  const tariNotice =
    state.tari?.active === true ? trackingNotice(state.earnings?.tari_confirmed) : null;
  const writable = state.control_enabled === true && connected && !sessionExpired;
  const actual = state.earnings_summary?.xmr;
  const partial = notice || actual?.partial !== false;
  return html`<div class="earnings-page">
    <section class="panel" aria-labelledby="payouts-title"><h2 id="payouts-title">Recorded payouts</h2>
      <p>Confirmed on-chain income, newest first. Recorded payouts are separate from expected returns.</p>
      ${notice ? html`<p>${notice} <a href=${link.href}>Advanced › Payout tracking</a>. A view key cannot spend.</p>` : null}
      ${tariNotice ? html`<p>Tari: ${tariNotice} <a href=${link.href}>Advanced › Payout tracking</a>.</p>` : null}
      <p class="muted">History range: ${state.window ? "the selected time window" : state.range || "not reported"}.</p>
      ${
        rows.length
          ? html`<ol class="payout-list">${rows.map(
              (row) => html`<li>
        <strong>${row.amount.toFixed(row.unit === "XMR" ? 12 : 6)} ${row.unit}</strong>
        <time datetime=${new Date(row.timestamp).toISOString()}>${new Date(row.timestamp).toLocaleString()}</time>
      </li>`,
            )}</ol>`
          : html`<p>No confirmed payouts are recorded in this history range. This does not mean you earned nothing.</p>`
      }
    </section>
    <section class="panel" aria-labelledby="expected-title"><h2 id="expected-title">Expected and actual</h2>
      <p>${ESTIMATES_PENDING}</p>
      <dl class="earnings-facts"><div><dt>Expected per day</dt><dd>Unavailable</dd></div>
        <div><dt>Expected per month</dt><dd>Unavailable</dd></div>
        <div><dt>Recorded Monero over 30 days</dt><dd>${
          actual?.enabled === true &&
          Number.isFinite(actual.actual_30d) &&
          (actual.actual_30d > 0 || (actual.actual_30d === 0 && !partial))
            ? `${actual.actual_30d.toFixed(12)} XMR${partial ? " · tracking may be incomplete" : ""}`
            : "Unavailable: view-only payout tracking is missing or has no reading"
        }</dd></div>
        <div><dt>Expected time to next share</dt><dd>Unavailable until dynamic window support is ready; never a payout countdown</dd></div>
      </dl>
      <p class="muted">Assumptions: network and difficulty inputs come from the configured node and P2Pool; their collection age is not reported for this page. ${priceAssumption(state.energy)} No fiat return is calculated.</p>
      ${state.energy?.cost_per_kwh > 0 ? html`<p>Electricity price is set; net after power remains unavailable with the return estimate.</p>` : null}
    </section>
    <section class="panel" aria-labelledby="bonus-title"><h2 id="bonus-title">XvB bonus and power</h2>
      <p>${xvbLine(state, connected)}</p>
      <p>${fleetLine(state.xmrig_donation)} <a href=${machinesLink.href}>Machines</a></p>
      ${
        writable
          ? html`<div class="earnings-controls">
        <${EarningsControl} kind="xvb" enabled=${true} onDirtyChange=${(dirty) => onDirtyChange?.("xvb", dirty)} />
        <${EarningsControl} kind="electricity" enabled=${true} onDirtyChange=${(dirty) => onDirtyChange?.("electricity", dirty)} />
      </div>`
          : html`<p>Settings are read-only${connected ? " on this host" : " while disconnected"}.</p>`
      }
    </section>
    ${
      state.tari?.active === true
        ? html`<section class="panel" aria-labelledby="tari-earnings-title"><h2 id="tari-earnings-title">Tari solo mining</h2>
      <dl class="earnings-facts"><div><dt>Full block reward</dt><dd>${connected && Number.isFinite(state.earnings?.tari_reward) && state.earnings.tari_reward > 0 ? `${state.earnings.tari_reward} XTM` : "Unavailable"}</dd></div>
        <div><dt>Expected block interval</dt><dd>Unavailable: verified input freshness is not reported</dd></div>
        <div><dt>Long-run average</dt><dd>Unavailable: verified input freshness is not reported</dd></div></dl>
      <p>Solo mining pays a full block when one is found; a long-run average is not a daily payment.</p>
    </section>`
        : null
    }
  </div>`;
}

export function priceAssumption(energy) {
  const source = energy?.price_source;
  if (source?.live && Number.isFinite(source.age_sec) && source.age_sec >= 0)
    return `Prices come from CoinGecko over Tor, fetched ${Math.floor(source.age_sec)} seconds ago.`;
  if (source?.feed)
    return "The price feed is waiting or its age is unavailable; configured fallback prices may be in use.";
  return "Prices are manually configured; their age is not reported.";
}
