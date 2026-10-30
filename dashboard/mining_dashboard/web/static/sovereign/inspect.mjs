import { Component, html } from "../app/preact.mjs";

const ROUTES = {
  tor: "Tor",
  clearnet: "Clearnet",
  incoming: "Incoming",
  lan: "LAN",
  local: "Local",
  inactive: "Inactive",
  unknown: "Unverified",
};
const read = (value) =>
  value === undefined || value === null || value === "" ? "Not reported" : String(value);

export class Inspect extends Component {
  constructor(props) {
    super(props);
    let internal = false;
    let preferenceError = "";
    try {
      internal = localStorage.getItem("dashboardTopoMesh") === "1";
    } catch {
      preferenceError = "Saved mesh preference is unavailable. Using the default for this visit.";
    }
    this.state = { internal, selected: null, preferenceError };
  }
  render({ state }, { internal, selected, preferenceError }) {
    const topology = state?.topology;
    const nodes = (topology?.nodes || []).filter(
      ({ internal: meshNode, id }) =>
        (internal || !meshNode) && (state?.tari?.active || id !== "tari"),
    );
    const ids = new Set(nodes.map((node) => node.id));
    const edges = (topology?.edges || []).filter(
      (edge) => ids.has(edge.from) && ids.has(edge.to) && (internal || edge.kind !== "internal"),
    );
    const node = nodes.find((entry) => entry.id === selected);
    const stats = [
      ["Monero mode", state?.monero?.mode],
      ["Monero health", state?.monero?.health?.status],
      [
        "Monero sync",
        Number.isFinite(state?.sync?.monero?.percent) ? `${state.sync.monero.percent}%` : null,
      ],
      ["P2Pool tier", state?.pool?.type],
      ["P2Pool hashrate", state?.pool?.hr],
      ["Pool peers", state?.pool?.peers],
      ["PPLNS window", state?.pool?.pplns_win],
      ["Pool uptime", state?.pool?.uptime],
      ["Network height", state?.network?.height],
      ["Network difficulty", state?.network?.diff],
      ["Network reward", state?.network?.reward],
      ...(state?.tari?.active
        ? [
            ["Tari health", state.tari.status],
            ["Tari height", state.tari.height],
          ]
        : []),
    ];
    return html`<section class="panel" aria-label="Configured topology">
      <h4>Configured topology</h4><p>Configured paths are not observed traffic or proof of reachability. Local or remote describes placement separately from transport.</p>
      <label><input type="checkbox" checked=${internal} onChange=${(event) => {
        this.setState({ internal: event.target.checked, preferenceError: "" });
        try {
          localStorage.setItem("dashboardTopoMesh", event.target.checked ? "1" : "0");
        } catch {
          this.setState({
            preferenceError:
              "The browser could not save the mesh preference. It applies only to this visit.",
          });
        }
      }} />Show the internal mesh</label>
      ${preferenceError ? html`<p role="status">${preferenceError}</p>` : null}
      ${
        topology
          ? html`<ul class="topology-map">${nodes.map(
              ({ id, label, remote, internal: meshNode }) => html`<li>
        <button type="button" aria-pressed=${id === selected} onClick=${() => this.setState({ selected: id })}>${label || id}</button>
        <span>${remote ? "Remote" : meshNode ? "Internal" : "Placement not reported"}</span>
      </li>`,
            )}</ul>
      <ul>${edges.map((edge) => html`<li>${edge.from} → ${edge.to}: ${ROUTES[edge.route] || "Unverified"} · ${edge.label}</li>`)}</ul>`
          : html`<p>Topology not reported.</p>`
      }
      ${
        node
          ? html`<section aria-label="Service inspector"><h5>${node.label || node.id}</h5><p>${node.remote ? "Remote node" : "Configured component"}. Reachability is not measured by this diagram.</p>
        <a href="?page=settings&advanced=node-and-network">Node and network settings</a></section>`
          : null
      }
      <p>RPC, ZMQ and gRPC reachability is not measured by this view. Review reported node health and use the node connection checks when available.</p>
      <h4>Node, network and pool statistics</h4><p>Snapshot time: ${read(state?.last_update)}</p>
      <dl class="facts">${stats.map(([label, data]) => html`<div><dt>${label}</dt><dd>${read(data)}</dd></div>`)}</dl>
    </section>`;
  }
}
