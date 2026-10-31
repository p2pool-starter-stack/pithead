import { html } from "../app/preact.mjs";
import { admission, duration, needsSync } from "./sync-model.mjs";

const verdict = (value, yes, no) => (value === true ? yes : value === false ? no : "Unknown");
const count = (value) =>
  typeof value === "number" && Number.isFinite(value) && value >= 0
    ? value.toLocaleString("en-US")
    : "Unknown";

export function SyncView({ state, history, connected, now = Date.now() / 1000 }) {
  const status = state.sync_status;
  const age = typeof status?.sampled_at === "number" ? Math.max(0, now - status.sampled_at) : null;
  const stale = !connected || age === null || age > 90;
  return html`<section class="sync-overview" aria-labelledby="sync-title">
    <h2 id="sync-title">Getting ready to mine</h2>
    <p role="status">${admission(state)}</p>
    <p>${connected ? (stale ? "Stale snapshot" : "Last successful snapshot") : "Disconnected — keeping the last successful snapshot"} · Sample age: ${duration(age)}</p>
    <div class="sync-nodes">${["monero", "tari"]
      .filter((name) => name === "monero" || status?.chains?.tari)
      .map((name) => {
        const node = status?.chains?.[name] || {};
        const { local: localNode } = node;
        const chain = state.sync?.[name];
        const measured = history?.eta(name, chain) ?? null;
        const eta =
          stale || node.reachable !== true
            ? null
            : node.synced === true
              ? 0
              : measured === 0
                ? null
                : measured;
        const progress =
          node.synced === true
            ? 100
            : chain?.target > 0 &&
                chain?.state === "syncing" &&
                typeof chain?.percent === "number" &&
                Number.isFinite(chain.percent)
              ? Math.max(0, Math.min(100, chain.percent))
              : null;
        return html`<article class="panel sync-node" aria-label=${name === "monero" ? "Monero sync" : "Tari sync"}>
        <h3>${name === "monero" ? "Monero" : "Tari"} · ${localNode === true ? "Local node" : localNode === false ? "Remote node" : "Node location unknown"}</h3>
        <p class="sync-headline">${progress === null ? "Progress unknown" : `${progress}%`} · ${eta === 0 ? "Sync complete" : eta === null ? "Estimate unavailable" : `Roughly ${duration(eta)} left`}</p>
        <progress max="100" value=${progress ?? undefined} aria-label=${`${name} sync progress`}></progress>
        <dl><dt>Reachability</dt><dd>${verdict(node.reachable, "Reachable", "Unreachable")}</dd>
          <dt>Synchronization</dt><dd>${verdict(node.synced, "Synced", "Not synced")}</dd>
          <dt>Chain health</dt><dd>${node.health?.level === "green" ? "Healthy" : node.health?.level === "red" ? "Unhealthy" : node.health?.level === "amber" ? "Degraded" : "Unknown"}${Array.isArray(node.health?.reasons) && node.health.reasons.length ? ` · ${node.health.reasons.join("; ")}` : ""}</dd>
          <dt>Recovery readiness</dt><dd>${verdict(node.healthy, "Stable reachability", "Waiting for stable reachability")}</dd>
          <dt>Blocks</dt><dd>${count(chain?.current)} / ${count(chain?.target)} · ${count(chain?.remaining)} remaining</dd>
          <dt>Database / mode</dt><dd>${chain?.db_size || "Unknown"} / ${chain?.mode || "Unknown"}</dd>
          <dt>Required-service recreation</dt><dd>${verdict(node.service_recreated, "Recreated", "Not recreated")}</dd></dl>
        ${localNode === false ? html`<p>Remote ${name === "monero" ? "Monero" : "Tari"} node: <span class="sync-address">${node.node || "Unknown"}</span>. Reported state: ${node.initializing || node.base_node_state || node.sync_state || verdict(node.synced, "SYNCED", "SYNCING")}. Initial sync: ${name === "monero" && node.initial_sync_achieved == null ? "Unknown — not reported by Monero" : verdict(node.initial_sync_achieved, "achieved", "not yet achieved")}. Waiting: ${duration(node.wait_seconds)}.</p>` : null}
        ${node.error ? html`<p role="status">Last probe error: ${node.error}</p>` : null}
        ${node.recovery_remaining > 0 ? html`<p>Recovery window: ${duration(node.recovery_remaining)} remaining with continuous reachability.</p>` : null}
      </article>`;
      })}</div>
    ${state.profile?.name ? html`<p>Active profile: ${state.profile.name}. <a href="?page=settings">Performance syncs faster — see Settings</a>.</p>` : null}
  </section>`;
}

export function overviewContent({ page, state, history, connected, renderPage }) {
  return page === "overview" && needsSync(state)
    ? html`<${SyncView} state=${state} history=${history} connected=${connected} />`
    : renderPage?.(page, state);
}
