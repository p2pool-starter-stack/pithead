import { StatCard } from "../system/statcards.mjs";
import { EstTable } from "../xvb/esttable.mjs";
import { XvbTierBlock } from "../xvb/xvbview.mjs";
import { EnergyPanel } from "./energy.mjs";
import {
  coinFiat,
  computeEarnings,
  formatAgo,
  formatFiat,
  formatFiatPrice,
  formatTimeToShare,
  formatXmr,
  formatXtm,
  loadPref,
  parseHashrate,
  priceSourceLabel,
  savePref,
} from "./logic.mjs";
import { Component, html } from "./preact.mjs";

// Expected vs actual (#808, reshaped by #817): the comparison the operator otherwise assembles
// by hand across the Earnings tabs, compact enough to be the Simple view's one earnings card.
// Deliberately carries NEITHER view class — card-simple and card-advanced are disjoint (each
// hides in the other's mode), and this is the one earnings surface both views share.
// The server rolls the rows up (build_earnings_vs_actual — window-matched hashrate, same
// confirmed roll-up as the Earnings card); this renders them. ONE shared 30d window for every
// stream (#817). Monero and XvB are ONE combined row: a win pays out through ordinary small
// payouts the payout table cannot attribute, so the confirmed actual already contains XvB XMR —
// the expectation folds XvB's published estimate in so pct compares like with like. Tari stays
// BLOCKS (solo merge-mining pays whole blocks — a count, not a percent); the XvB row keeps only
// its win count, its XMR lives in the combined row by construction. A stream with payout
// confirmation off shows the config key to set instead of a zero that would read as "earned
// nothing"; the card yields to nothing when no stream has anything to compare. The table wraps
// (eva-table) instead of panning — this card never scrolls in either view (#817).
function ExpectedVsActualCard({ summary }) {
  if (!summary) return null;
  const { xmr, tari, xvb } = summary;
  if (!xmr.available && !tari.available && !xvb.enabled) return null;
  const partialMark = (row, text) => (row.partial ? text + " *" : text);
  const anyPartial = (xmr.enabled && xmr.partial) || (tari.enabled && tari.partial);
  const rows = [];
  // The server withholds pct past 999%: a near-zero expectation (a box idle for most of the
  // window) turns the ratio into a five-digit figure that reads as a bug. Once available and
  // enabled both hold, a null pct means exactly that — the tooltip owns the explanation.
  const pctNote =
    xmr.available && xmr.enabled && xmr.pct === null
      ? " No percentage shown: the expected figure is near zero for this window — the miner " +
        "was idle or unrecorded for most of it, so a ratio against it would be noise."
      : "";
  rows.push({
    label: xmr.includes_xvb ? "Monero + XvB (30d)" : "Monero (30d)",
    expected: xmr.available ? formatXmr(xmr.expected_30d) : "—",
    actual: !xmr.enabled
      ? "set monero.view_key"
      : partialMark(xmr, formatXmr(xmr.actual_30d) + (xmr.pct !== null ? ` (${xmr.pct}%)` : "")),
    dim: !xmr.enabled,
    title:
      (xmr.includes_xvb
        ? "Confirmed on-chain payouts over the trailing 30 days vs the P2Pool linear expectation " +
          "at your 30-day average hashrate PLUS XvB's estimate for your tier — combined " +
          "on both sides, because an XvB win pays out through ordinary payouts that cannot be " +
          "told apart from P2Pool payouts. " +
          (xmr.xvb_realization_pct !== null
            ? `The XvB share is tempered to this wallet's measured win payouts — ` +
              `${xmr.xvb_realization_pct}% of XvB's published face value over the last ` +
              `${xmr.xvb_wins_measured} wins. `
            : "The XvB share is XvB's published face-value estimate — an upper bound: it prices " +
              "every bonus hash at full block reward and assumes every won round runs to " +
              "completion. ") +
          "Payouts swing with luck; a sustained gap is the signal worth checking, not one window."
        : "Confirmed on-chain payouts over the trailing 30 days vs the linear expectation at " +
          "your 30-day average P2Pool hashrate. Any XvB win payouts land in the actual too — " +
          "they cannot be told apart from P2Pool payouts. Payouts swing with luck; a sustained " +
          "gap is the signal worth checking, not one window.") + pctNote,
  });
  rows.push({
    label: "Tari (30d)",
    // Two significant digits, not a fixed decimal: at real Tari difficulty the expectation is a
    // FRACTION of a block per month, and "0.0" would erase exactly the number this row exists
    // to show (≈ 0.0052 blocks is the honest, legible form).
    expected: tari.available ? `≈ ${Number(tari.expected_blocks_30d.toPrecision(2))} blocks` : "—",
    actual: !tari.enabled
      ? "set tari.view_key"
      : partialMark(
          tari,
          `${tari.blocks_30d} block${tari.blocks_30d === 1 ? "" : "s"} · ${formatXtm(tari.xtm_30d)}`,
        ),
    dim: !tari.enabled,
    title:
      "Tari is merge-mined SOLO: a confirmed payout IS a found block, all at once. Expected is " +
      "your 30-day average hashrate × 30 days ÷ the Tari difficulty — at fractions of a block " +
      "per month, zero found is the normal case, not a fault.",
  });
  if (xvb.enabled) {
    rows.push({
      label: "XvB wins (30d)",
      // Forecast from XvB's own winners file (#866): round-type frequency ÷ qualifier count for
      // the held tier. Two significant digits, same honesty rule as the Tari row. "—" while the
      // aggregate is missing or stale — never a guess.
      expected:
        xvb.expected_wins_30d != null
          ? `≈ ${Number(xvb.expected_wins_30d.toPrecision(2))} wins`
          : "—",
      actual:
        `${xvb.wins_30d} win${xvb.wins_30d === 1 ? "" : "s"}` +
        (xvb.last_win_ts ? ` · last ${formatAgo(xvb.last_win_ts)}` : ""),
      dim: false,
      title:
        "Raffle wins recorded in the last 30 days (last-win recency can predate the window). " +
        "Expected is computed from XvB's public winners file: how often your tier's rounds are " +
        "drawn ÷ how many qualifiers they have — for the tier you hold, or the tier you're " +
        "targeting while none is held yet. A win's XMR arrives through ordinary payouts, " +
        "so its value is counted in the Monero + XvB row above — this row tracks the draw.",
    });
  }
  return html`
    <div class="card" id="card-expected-vs-actual">
        <h3>Earnings — Expected vs Actual</h3>
        <table class="est-table eva-table">
            <thead><tr>
                <th></th>
                <th scope="col">Expected</th>
                <th scope="col">Actual</th>
            </tr></thead>
            <tbody>
                ${rows.map(
                  (r) => html`
                <tr title=${r.title}>
                    <th scope="row">${r.label}</th>
                    <td class="c-accent">${r.expected}</td>
                    <td class=${r.dim ? "text-muted" : ""}>${r.actual}</td>
                </tr>`,
                )}
            </tbody>
        </table>
        ${
          anyPartial
            ? html`<p class="text-muted text-xs">* covers only the payout history on record, not the window's full span.</p>`
            : null
        }
    </div>`;
}

// P2Pool earnings calculator (Issue #12). A power-user card (Advanced view) over the metrics
// layer that estimates XMR from *P2Pool mining only* — explicitly not XvB — plus the Tari the
// same hashrate merge-mines alongside it (#117; "—" while merge-mining is inactive). The server
// sends the daily XMR and XTM rates per H/s; this card scales both to a what-if hashrate.
// Stateful because the what-if input is local UI: `input` is null until the user edits it, so
// the field tracks the live P2Pool 1h-average hashrate (the same `p2pool_hr` figure the header /
// Overview show, which already excludes the XvB-donated slice) until they take control, then
// holds their raw text.
// Confirmed on-chain payouts (#381), shown beside the estimate when the view-only wallet feature
// is on (`c.enabled`). Reads the unit-prefixed totals the server rolls up in
// confirmed_payouts_summary (`xmr_*` for Monero, `xtm_*` for Tari); `fmt` is the matching coin
// formatter and `unit` (XMR / XTM) picks the key prefix. Renders nothing when the feature is off,
// so the estimate stands alone.
// The running windows (#787) — yesterday, 7d, 30d — are what an operator checks against the
// estimate above; they carry a `*` and a footnote when the server flagged them partial, so a
// window summed over less history than its label claims never reads as a complete one. The date
// comes from `since_ts` (oldest payout on record) formatted in the VIEWER's locale, while the
// day boundaries were cut in the dashboard container's timezone — close enough to place the
// history, and the footnote says "starts", not a to-the-hour claim.
function confirmedBlock(c, fmt, unit) {
  if (!c || !c.enabled) return null;
  const k = unit.toLowerCase();
  const n = c.count || 0;
  const partial = c.partial || {};
  const anyPartial = ["yesterday", "7d", "30d"].some((w) => partial[w]);
  const since = c.since_ts ? new Date(c.since_ts * 1000).toLocaleDateString() : null;
  const hint = since
    ? `Partial — payout history starts ${since}`
    : "Partial — no payouts on record yet";
  const running = (key, label) => html`
    <${StatCard} label=${partial[key] ? `${label} *` : label}
                 value=${fmt(c[`${k}_${key}`])}
                 title=${partial[key] ? hint : ""} />`;
  const note = `* ${hint.replace("Partial — ", "")} — the window covers only the history on record, not its full span.`;
  return html`
    <div class="confirmed-block">
      <h4 class="confirmed-subhead">Confirmed on-chain</h4>
      <div class="stat-grid">
        ${running("yesterday", "Yesterday")}
        <${StatCard} label="Confirmed 24h" value=${fmt(c[`${k}_24h`])} />
        ${running("7d", "Running 7d")}
        ${running("30d", "Running 30d")}
        <${StatCard} label="Confirmed all-time" value=${fmt(c[`${k}_all`])} />
        <${StatCard} label="Last payout" value=${formatAgo(c.last_ts)}
                     title=${"Across " + n + " confirmed payout" + (n === 1 ? "" : "s")} />
      </div>
      ${anyPartial ? html`<p class="text-muted text-xs">${note}</p>` : null}
    </div>`;
}

class EarningsCard extends Component {
  constructor(props) {
    super(props);
    // `input` (what-if hashrate) is SHARED across tabs — it lives above the tab strip so switching
    // tabs keeps the entered value. `tab` is the active earnings tab (Monero / Tari / XvB),
    // persisted (#658); render() already falls back to monero when the saved tab isn't available.
    this.state = {
      input: null,
      tab: loadPref("dashboardEarningsTab", ["monero", "tari", "xvb", "energy"], "monero"),
    };
    this.onInput = (e) => this.setState({ input: e.target.value });
    this.onTab = (tab) => {
      savePref("dashboardEarningsTab", tab);
      this.setState({ tab });
    };
  }

  render() {
    const e = this.props.earnings;
    if (!e || !e.available) {
      return html`
            <div class="card card-advanced" id="card-earnings">
                <h3>P2Pool Earnings (estimated)</h3>
                <p class="text-muted text-small">Network stats unavailable — the estimate can't be computed right now.</p>
            </div>`;
    }
    const { input, tab } = this.state;
    const useDefault = input === null;
    // Default to your P2Pool 1h-average hashrate (the figure shown in the header / Overview,
    // already excluding the XvB-donated slice); once edited, use the parsed what-if value.
    const hr = useDefault ? e.p2pool_hr : parseHashrate(input);
    const est = computeEarnings(hr, e);
    const xvb = this.props.xvb;
    const energy = this.props.energy;
    // Tabs split the (now multi-domain) card body. The XvB tab stays with XvB disabled (#938) —
    // its decision table is exactly the "should I enable it?" aid — as long as the server sent a
    // tier table (a pre-#938 disabled payload carries none, and enabled always does). Energy only
    // appears when the fleet reports any power — there's nothing to show otherwise. The one
    // what-if input above the strip drives every tab's estimate.
    const showXvb = !!(xvb && (xvb.enabled || (xvb.tiers || []).length));
    const tabs = [
      { id: "monero", label: "Monero" },
      { id: "tari", label: "Tari" },
    ];
    if (showXvb) tabs.push({ id: "xvb", label: "XvB" });
    if (energy && energy.available) tabs.push({ id: "energy", label: "Energy" });
    const active = tabs.some((t) => t.id === tab) ? tab : "monero";
    // Fiat estimates (#520): each tab grows ≈-fiat rows once its coin's price is known — static
    // from config.json or live from the opt-in CoinGecko-over-Tor feed. The footer line below
    // states which price the figures are valued at, so a fiat number is never unattributed.
    const priceSrc = priceSourceLabel(energy);
    const priceTitle = "At the price shown in the Prices line below — an estimate, not a payout.";
    return html`
        <div class="card card-advanced" id="card-earnings">
            <h3>P2Pool Earnings (estimated)</h3>
            <details class="earnings-details">
                <summary>About this estimate</summary>
                <p class="text-muted text-xs earnings-subtitle">Estimated XMR from P2Pool mining plus the Tari merge-mined alongside it — excludes XvB donations.</p>
                <p class="earnings-disclaimer text-muted text-xs mt-2">${e.disclaimer}</p>
            </details>
            <div class="earnings-input">
                <label for="whatif-hr">Your P2Pool Hashrate</label>
                <input id="whatif-hr" type="text" inputmode="decimal" spellcheck="false"
                       autocomplete="off" value=${useDefault ? e.p2pool_hr_str : input}
                       onInput=${this.onInput} />
            </div>
            <div class="earnings-tabs" role="tablist" aria-label="Earnings breakdown">
                ${tabs.map(
                  (t) => html`
                    <button role="tab" type="button"
                            id=${"etab-" + t.id} aria-controls=${"epanel-" + t.id}
                            aria-selected=${active === t.id ? "true" : "false"}
                            class=${"earnings-tab" + (active === t.id ? " is-active" : "")}
                            onClick=${() => this.onTab(t.id)}>${t.label}</button>`,
                )}
            </div>

            <div role="tabpanel" id="epanel-monero" aria-labelledby="etab-monero" hidden=${active !== "monero"}>
                <${EstTable} unit="XMR" day=${est.day} month=${est.month} year=${est.year}
                             price=${energy ? energy.xmr_price : 0} currency=${energy ? energy.currency : "USD"}
                             title=${priceTitle} />
                <div class="stat-grid">
                    <${StatCard} label="Time / Share" value=${formatTimeToShare(est.timeToShareSec)} />
                    <${StatCard} label="XMR Block Reward" value=${e.block_reward} />
                </div>
                ${confirmedBlock(e.confirmed, formatXmr, "XMR")}
            </div>

            <div role="tabpanel" id="epanel-tari" aria-labelledby="etab-tari" hidden=${active !== "tari"}>
                <div class="stat-grid">
                    <${StatCard} label="Est. Time to Tari Block" value=${formatTimeToShare(est.tariTimeToBlockSec)}
                                 title="Tari is merge-mined SOLO: the whole block reward lands at once when your hashrate finds a Tari block, roughly this often (difficulty ÷ your hashrate). Shows — while merge-mining is inactive or syncing." />
                    <${StatCard} label="XTM per Block" value=${formatXtm(est.tariRewardPerBlock)} cls="text-accent"
                                 title="The full Tari block reward paid when you solo-find a block — you get all of it at once, not spread over time." />
                    ${
                      energy && energy.tari_price > 0
                        ? html`
                    <${StatCard} label="≈ per Block" value=${formatFiat(coinFiat(est.tariRewardPerBlock, energy.tari_price), energy.currency)} title=${priceTitle} />`
                        : null
                    }
                </div>
                <h4 class="est-heading" title="Long-run average, NOT steady income. Solo merge-mining pays the whole block reward at once, roughly every 'time to Tari block' — these figures just spread that lumpy payout out on paper.">
                    Long-run Average — not steady income</h4>
                <${EstTable} unit="XTM" day=${est.tariDay} month=${est.tariMonth} year=${est.tariYear}
                             price=${energy ? energy.tari_price : 0} currency=${energy ? energy.currency : "USD"}
                             title=${priceTitle} />
                ${confirmedBlock(e.tari_confirmed, formatXtm, "XTM")}
            </div>

            ${
              showXvb
                ? html`
            <div role="tabpanel" id="epanel-xvb" aria-labelledby="etab-xvb" hidden=${active !== "xvb"}>
                <${XvbTierBlock} calc=${xvb} hr=${hr} coeffDay=${e.coeff_day} energy=${energy} est=${est} />
            </div>`
                : null
            }
            ${
              energy && energy.available
                ? html`
            <div role="tabpanel" id="epanel-energy" aria-labelledby="etab-energy" hidden=${active !== "energy"}>
                <${EnergyPanel} energy=${energy} est=${est} />
            </div>`
                : null
            }
            ${
              priceSrc
                ? html`<p class="text-muted text-xs mt-2" id="earnings-price-source">
                    Prices: XMR ${formatFiatPrice(energy.xmr_price, energy.currency)} · XTM ${formatFiatPrice(energy.tari_price, energy.currency)} — ${priceSrc}
                </p>`
                : null
            }
        </div>`;
  }
}

export { EarningsCard, ExpectedVsActualCard };
