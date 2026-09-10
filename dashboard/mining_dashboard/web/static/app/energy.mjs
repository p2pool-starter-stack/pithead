import { StatCard } from "../system/statcards.mjs";
import { computeEnergy, formatFiatAmount, formatUnit } from "./logic.mjs";
import { html } from "./preact.mjs";
import { netCls } from "./ui.mjs";

// Energy & profit tab body (#260). Fleet power draw + efficiency (always, when any power is known),
// then energy cost once an electricity price is set, then net profit once an XMR price is also set —
// each layer appears only when its inputs exist, so the operator never sees a fabricated figure.
// Setting a Tari price too (#520) folds the Tari merge-mining estimate into gross, and the current
// XvB tier's expected reward — tempered by measured delivery server-side (#902), never face
// value — folds in when XvB sends a fresh one (#712); the heading and the Net/day tooltip say
// exactly what's counted — including that XvB is a tempered estimate — so the net is never
// silently partial or over-confident. `est` is the earnings for the shared what-if hashrate;
// the client does the kWh/cost/net math.
function EnergyPanel({ energy, est }) {
  const en = computeEnergy(energy, est);
  const cur = energy.currency;
  const haveCost = energy.cost_per_kwh > 0;
  const haveNet = haveCost && energy.xmr_price > 0;
  // Honest label (#520, #712, #902): say exactly what gross counts so the net figure is never
  // silently partial. XvB is tagged "(est.)" — the current tier's expected reward, tempered by
  // measured delivery server-side, and the raffle draw is probabilistic. When XvB isn't folded
  // in, the strings are byte-identical to the pre-#712 label/tooltip.
  const netLabel = en.includesXvb
    ? en.includesTari
      ? "P2Pool + Tari + XvB (est.), after power"
      : "P2Pool + XvB (est.), after power"
    : en.includesTari
      ? "P2Pool + Tari, after power"
      : "P2Pool XMR only, after power";
  const netTitle = en.includesXvb
    ? en.includesTari
      ? "P2Pool XMR + Tari (merge-mined) earnings at your set prices, plus the current XvB tier's expected reward valued at your XMR price, minus power cost. XvB is an estimate, tempered by measured delivery (your wallet's measured win payouts when enough wins exist, else the measured delivery band's midpoint) — never XvB's face value — and the raffle draw is random among qualifiers."
      : "P2Pool XMR earnings at your XMR price plus the current XvB tier's expected reward valued at your XMR price, minus power cost. Excludes Tari (set dashboard.energy.tari_price to include it). XvB is an estimate, tempered by measured delivery (your wallet's measured win payouts when enough wins exist, else the measured delivery band's midpoint) — never XvB's face value — and the raffle draw is random among qualifiers."
    : en.includesTari
      ? "P2Pool XMR + Tari (merge-mined) earnings at your set prices, minus power cost. Excludes XvB (raffle status, not a per-day income estimate)."
      : "P2Pool XMR earnings at your XMR price, minus power cost. Excludes Tari (set dashboard.energy.tari_price to include it) and XvB (raffle status, not a per-day income estimate).";
  // One standardized Day/Month/Year table for the whole money side: kWh always, then Revenue /
  // Cost / Net columns as their inputs exist (same appearance gates as before — never a
  // fabricated figure). Revenue is the gross the net starts from, so the estimate is no longer
  // implicit; Net keeps the one judgment colour (green profit / red loss).
  const rows = [
    ["Day", en.kwhDay, en.grossDay, en.costDay, en.netDay],
    ["Month", en.kwhMonth, en.grossMonth, en.costMonth, en.netMonth],
    ["Year", en.kwhYear, en.grossYear, en.costYear, en.netYear],
  ];
  return html`
    <div class="stat-grid">
        <${StatCard} label="Fleet Power" value=${formatUnit(energy.total_watts, "W")}
                     cls=${energy.incomplete ? "status-warn" : ""}
                     title=${
                       energy.incomplete
                         ? "Summed draw of the workers that report power (RAPL) or have a configured estimate — a lower bound: some workers report neither and are excluded."
                         : "Summed measured/estimated draw across the fleet."
} />
        <${StatCard} label="Efficiency" value=${formatUnit(energy.hs_per_watt, "H/s·W", 2)}
                     title="Fleet hashrate ÷ fleet watts." />
    </div>
    <h4 class="est-heading">Energy${haveCost ? ` — Cost${haveNet ? ` & Net Profit, ${netLabel}` : ""} (${cur})` : ""}</h4>
    <div class="est-scroll">
    <table class="est-table">
        <thead><tr>
            <th></th>
            <th scope="col">kWh</th>
            ${haveNet ? html`<th scope="col" title=${netTitle}>Revenue (est.)</th>` : null}
            ${haveCost ? html`<th scope="col">Power Cost</th>` : null}
            ${haveNet ? html`<th scope="col" title=${netTitle}>Net</th>` : null}
        </tr></thead>
        <tbody>
            ${rows.map(
              ([label, kwh, gross, cost, net]) => html`
            <tr>
                <th scope="row">${label}</th>
                <td>${formatUnit(kwh, "")}</td>
                ${haveNet ? html`<td class="c-accent">${formatFiatAmount(gross)}</td>` : null}
                ${haveCost ? html`<td>${formatFiatAmount(cost)}</td>` : null}
                ${haveNet ? html`<td class=${netCls(net)} title=${netTitle}>${formatFiatAmount(net)}</td>` : null}
            </tr>`,
            )}
        </tbody>
    </table>
    </div>
    ${
      haveCost
        ? haveNet
          ? null
          : html`<p class="text-muted text-xs mt-2">Set <code>dashboard.energy.xmr_price</code> (in your currency), or <code>dashboard.energy.price_feed: true</code> to fetch live prices from CoinGecko over Tor (opt-in — off by default, no clearnet egress), to see revenue and net profit.</p>`
        : html`<p class="text-muted text-xs mt-2">Set <code>dashboard.energy.cost_per_kwh</code> to see energy cost and net profit after power.</p>`
    }`;
}

export { EnergyPanel };
