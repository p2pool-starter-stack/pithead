import { MoreStats, nodeLocation, StatCard, TariStatus } from "../system/statcards.mjs";
import { raffleCls } from "./logic.mjs";
import { html } from "./preact.mjs";
import { cVar, SharesStat } from "./ui.mjs";

// --- Operational cards ---------------------------------------------------------------

function Overview({ state }) {
  const hr = state.hashrate,
    st = state.stratum,
    t = state.tari,
    xvbOn = !!(state.xvb_calc && state.xvb_calc.enabled);
  // Stat order (#159): fleet headline (total / mode / workers) → raffle status (tier / VIP /
  // shares / target) → routed split → reference (last share / Tari / wallets).
  return html`
    <div class="card card-simple" id="card-overview">
        <h3>Overview</h3>
        <div class="stat-grid">
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Workers Alive" value=${state.proxy_workers} />
            ${
              // Five of these tiles are raffle/split state — on a non-donating box they'd all
              // read None / N/A / zeros, a third of the Overview spent saying "off" five ways.
              // The mode tile already says it once.
              xvbOn
                ? html`
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Raffle Eligible" value=${state.raffle_eligible.label} cls=${raffleCls(state.raffle_eligible)} />`
                : null
            }
            <${SharesStat} sw=${state.shares_window} />
            ${xvbOn ? html`<${StatCard} label="Target Tier" value=${hr.target_tier} />` : null}
            <${StatCard} label="P2Pool 1h (routed)" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h (routed)" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            ${
              xvbOn
                ? html`
            <${StatCard} label="XvB 1h (routed)" value=${hr.xvb_routed_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label="XvB 24h (routed)" value=${hr.xvb_routed_24h} cls=${cVar(hr.xvb_variant)} />`
                : null
            }
            <${StatCard} label="Last Share" value=${st.last_share} />
            <div class="stat-card"><h5>Tari Mining</h5><${TariStatus} tari=${t} /></div>
            <${StatCard} label="Wallet XMR" value=${st.wallet_short} cls="font-mono text-xs" />
            <${StatCard} label="Wallet TARI" value=${t.wallet_short} cls="font-mono text-xs" />
        </div>
    </div>`;
}

function NodeStats({ state }) {
  const hr = state.hashrate,
    st = state.stratum;
  // Headline = the figures an operator actually checks first (mode, total hashrate, routed
  // averages, share health); stratum windows, connections, effort and the rest are drill-down
  // detail behind the "show more" toggle (progressive disclosure).
  const headline = html`
            <${StatCard} label="Mining Mode" value=${hr.mode_name} cls=${cVar(hr.mode_variant)} />
            <${StatCard} label="Total Hashrate" value=${hr.total} cls="text-accent" />
            <${StatCard} label="P2Pool 1h Avg" value=${hr.p2p_1h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="P2Pool 24h Avg" value=${hr.p2p_24h} cls=${cVar(hr.p2p_variant)} />
            <${StatCard} label="Shares (OK/Err)" value=${st.shares} />`;
  const detail = html`
            <div class="stat-card col-span-2">
                <h5>Stratum (15m / 1h / 24h)</h5>
                <p class="text-small">${st.h15} / ${st.h1h} / ${st.h24h}</p>
            </div>
            <${StatCard} label="Connections" value=${st.conns} />
            <${StatCard} label="Effort" value=${st.effort} />
            <${StatCard} label="Reward Share" value=${st.reward_pct} />
            <${StatCard} label="Total Shares" value=${st.total_shares} />
            <${StatCard} label="Last Share" value=${st.last_share} />
            <${StatCard} label="Total Hashes (Node)" value=${st.total_hashes} span=${true} />`;
  return html`
    <div class="card card-advanced" id="card-mynode">
        <h3>My P2Pool Node Stats</h3>
        <${MoreStats} prefKey="dashboardCardNode" headline=${headline} detail=${detail} count=${12} />
        <div class="wallet-text">Wallet: ${st.wallet}</div>
    </div>`;
}

function GlobalStats({ state }) {
  const p = state.pool;
  // Headline = the pool's own money/health figures (hashrate, whether it's finding blocks, when
  // it last did); sidechain internals, peers and uptime are reference detail, not a glance figure.
  const headline = html`
            <${StatCard} label="Pool Hashrate" value=${p.hr} cls="text-accent" />
            <${StatCard} label="Blocks Found" value=${p.blocks} />
            <div class="stat-card"><h5>Last Block</h5><p class="text-small">${p.last_blk}</p></div>`;
  const detail = html`
            <${StatCard} label="Miners" value=${p.miners} />
            <${StatCard} label="Sidechain Height" value=${p.sidechain_height} />
            <${StatCard} label="Difficulty" value=${p.diff} />
            <${StatCard} label="PPLNS Window" value=${p.pplns_win} />
            <${StatCard} label="PPLNS Weight" value=${p.pplns_wgt} />
            <${SharesStat} sw=${state.shares_window} />
            <${StatCard} label="Peers" value=${p.peers} />
            <div class="stat-card"><h5>Uptime</h5><p class="text-small">${p.uptime}</p></div>
            <${StatCard} label="Total Hashes (Pool)" value=${p.total_hashes} />`;
  return html`
    <div class="card card-advanced" id="card-global">
        <h3>Global P2Pool Stats</h3>
        <${MoreStats} prefKey="dashboardCardGlobal" headline=${headline} detail=${detail} count=${12} />
    </div>`;
}

function XvBStats({ state }) {
  const hr = state.hashrate;
  // A non-donating box gets no XvB stats card at all — every figure in it would be a zero or a
  // "None", and the tier calculator alongside already hides itself the same way.
  if (!(state.xvb_calc && state.xvb_calc.enabled)) return null;
  // When the xmrvsbeast.com fetch is stale (#311) the CREDITED figures are frozen —
  // grey them and tag the label so they don't read as live. Routed (our own proxy
  // history) is unaffected. Tooltip explains why.
  const staleTitle =
    "Stale: no successful fetch from xmrvsbeast.com since the time below. The credited " +
    "figures are frozen at the last reading; the controller holds its split until a fresh read lands.";
  const credLabel = (base) => (hr.xvb_stale ? base + " ⚠" : base);
  const credCls = hr.xvb_stale ? "status-warn" : cVar(hr.xvb_variant);
  const credTitle = hr.xvb_stale ? staleTitle : "";
  return html`
    <div class="card card-advanced" id="card-xvb">
        <h3>XvB Donation Stats</h3>
        <div class="stat-grid">
            <${StatCard} label="Current Tier" value=${hr.tier} />
            <${StatCard} label="Target Tier" value=${hr.target_tier} />
            <${StatCard} label="1h Avg (Routed)" value=${hr.xvb_routed_1h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label=${credLabel("1h Avg (Credited)")} value=${hr.xvb_1h} cls=${credCls} title=${credTitle} />
            <${StatCard} label="24h Avg (Routed)" value=${hr.xvb_routed_24h} cls=${cVar(hr.xvb_variant)} />
            <${StatCard} label=${credLabel("24h Avg (Credited)")} value=${hr.xvb_24h} cls=${credCls} title=${credTitle} />
            <${StatCard} label="Fail Count" value=${hr.xvb_fail_count} />
        </div>
        <div class="mt-2">
            <div class="text-small text-muted">Raffle Wins</div>
            <div class="raffle-wins-list">
            ${
              (state.raffle_wins || []).length
                ? state.raffle_wins.map(
                    (w) => html`<div class="text-xs" title=${"Round block height " + w.height}>
                        ★ ${w.time} — won a ${w.tier} round, credited ${w.hashrate}</div>`,
                  )
                : html`<div class="text-xs text-muted">No wins recorded yet — a win lands here and as a gold star on the chart.</div>`
            }
            </div>
        </div>
        <div class=${"text-xs mt-2 " + (hr.xvb_stale ? "status-warn" : "text-muted")} title=${credTitle}>
            ${hr.xvb_stale ? "⚠ Stale — last successful fetch from xmrvsbeast.com: " : "Stats fetched from xmrvsbeast.com (Updated: "}${hr.xvb_updated}${hr.xvb_stale ? "" : ")"}
        </div>
    </div>`;
}

function NetworkCard({ state }) {
  const n = state.network,
    m = state.monero;
  // Headline = the chain's own money/health figures (height, difficulty, block reward); node
  // internals (mode, DB size, hash, network time) are reference detail.
  const headline = html`
            <${StatCard} label="Block Height" value=${n.height} />
            <${StatCard} label="Difficulty" value=${n.diff} />
            <${StatCard} label="Reward" value=${n.reward} />`;
  const detail = html`
            <${StatCard} label="Node" value=${nodeLocation(state.sync?.monero?.local)}
                title="Whether this stack runs its own monerod or points at somebody else's" />
            <${StatCard} label="Node Mode" value=${m.mode} />
            <${StatCard} label="DB Size" value=${m.db_size} />
            <div class="stat-card col-span-2"><h5>Current Block Hash</h5><p class="font-mono text-xs">${n.hash}</p></div>
            <${StatCard} label="Network Time" value=${n.ts} span=${true} />`;
  return html`
    <div class="card card-advanced" id="card-network">
        <h3>XMR Network</h3>
        <${MoreStats} prefKey="dashboardCardNetwork" headline=${headline} detail=${detail} count=${8} />
    </div>`;
}

// Pool cadence & luck (#84). Read-only Advanced card over server-formatted figures: time since the
// pool's last block (pool-wide, not a payout to you), the expected time for your hashrate to find a
// sidechain share, luck, and YOUR PPLNS share-weight (sum of your share difficulty in the window —
// not p2pool's pool-wide pplnsWeight shown in the node stats).
function CadenceCard({ cadence }) {
  if (!cadence) return null;
  return html`
    <div class="card card-advanced" id="card-cadence">
        <h3>Pool Cadence & Luck</h3>
        <div class="stat-grid">
            <${StatCard} label="Since Pool's Last Block" value=${cadence.since_block}
                         title=${"Last block the pool found (" + cadence.last_block + ") — pool-wide, not a payout to you."} />
            <${StatCard} label="Est. Time / Share" value=${cadence.tts}
                         title="Expected time for your P2Pool hashrate to find one sidechain share (share difficulty ÷ your 1h average)." />
            <${StatCard} label="Luck" value=${cadence.luck}
                         title="Actual vs expected shares in the PPLNS window, as a percentage. Over 100% = running lucky." />
            <${StatCard} label="Your PPLNS Weight" value=${cadence.weight}
                         title="Sum of your share difficulty inside the PPLNS window — your slice of the next payout. Not the pool-wide PPLNS weight." />
        </div>
    </div>`;
}

function TariCard({ tari, local }) {
  return html`
    <div class="card card-advanced" id="card-tari">
        <h3>Tari Merge-Mining</h3>
        <div class="stat-grid">
            <div class="stat-card"><h5>Status</h5><${TariStatus} tari=${tari} /></div>
            <${StatCard} label="Reward" value=${tari.reward} />
            <${StatCard} label="Height" value=${tari.height} />
            <${StatCard} label="Difficulty" value=${tari.diff} />
            <${StatCard} label="Node" value=${nodeLocation(local)}
                title="Whether this stack runs its own Tari base node or points at somebody else's" />
        </div>
        <div class="wallet-text">Wallet: ${tari.wallet}</div>
    </div>`;
}

export { CadenceCard, GlobalStats, NetworkCard, NodeStats, Overview, TariCard, XvBStats };
