import { UpgradeControl } from "../config/configview.mjs";
import { OnionUrl } from "../network/onionurl.mjs";
import { OsUpdateControl } from "../system/osupdate.mjs";
import { html } from "./preact.mjs";
import { Badges, cVar, HighUsage, UpdateBadge, VersionBadge } from "./ui.mjs";

// --- Top bar -------------------------------------------------------------------------

function Header({ state }) {
  const s = state.system,
    hr = state.hashrate;
  const labelCls = (level) => (level === "high" ? "status-bad" : "text-muted");
  const valCls = (level) => (level === "high" ? "status-bad" : "");
  return html`
    <div class="header" id="top-header">
        <div>
            <div class="brand">
                <img class="brand-logo" src="/static/pithead-mark.svg" alt="" width="40" height="40" />
                <div>
                    <div class="flex items-center">
                        <h1 class="brand-name">Pithead</h1>
                        <${Badges} badges=${state.badges} />
                        <${VersionBadge} version=${state.version} />
                        <${UpdateBadge} update=${state.update} />
                        ${
                          // The appliance updates through signed OS images (state.os_update
                          // present), so the tarball Upgrade button yields to the OS control —
                          // the host would refuse its verb there anyway.
                          state.os_update
                            ? html`<${OsUpdateControl} os=${state.os_update} update=${state.update}
                                  version=${state.version} enabled=${state.control_enabled} />`
                            : html`<${UpgradeControl} update=${state.update} enabled=${state.control_enabled} />`
                        }
                    </div>
                    <div class="brand-host font-mono text-muted">${state.host_ip}${state.host_addr ? html`<span class="brand-host-at">@</span>${state.host_addr}` : null}</div>
                    <${OnionUrl} onion=${state.dashboard_onion} />
                </div>
            </div>
            <div class="text-small mt-2">
                <div class="mb-1">
                    <span class=${labelCls(s.cpu.level)}>CPU:</span>
                    <span class=${valCls(s.cpu.level)}>${s.cpu.percent}</span> <${HighUsage} level=${s.cpu.level} />
                    <span class="text-muted ml-2">Load:</span> ${s.cpu.load}
                </div>
                <div class="mb-1">
                    <span class=${labelCls(s.mem.level)}>RAM:</span>
                    <span class=${valCls(s.mem.level)}>${s.mem.used} / ${s.mem.total} GB (${s.mem.percent})</span> <${HighUsage} level=${s.mem.level} />
                    <span class=${s.hugepages.variant === "ok" ? "status-ok" : "status-bad"}>Huge Pages: ${s.hugepages.status} (${s.hugepages.value})</span>
                </div>
                <div class="flex items-center">
                    <span class=${(s.disk.level === "high" ? "status-bad" : "text-muted") + " mr-2"}>Disk: ${s.disk.used} / ${s.disk.total} ${s.disk.unit} (${s.disk.percent})</span> <${HighUsage} level=${s.disk.level} />
                    <div class="disk-bar">
                        <div class="progress-bg">
                            <div class=${"progress-fill " + s.disk.fill} style=${{ width: s.disk.width }}></div>
                        </div>
                    </div>
                </div>
            </div>
        </div>
        <div class="text-right">
            <div class="text-muted text-xs">Last Update: ${state.last_update}</div>
            <div class=${"text-xs mt-1 " + cVar(hr.p2p_variant)}>P2Pool (routed): ${hr.p2p_1h} (1h) / ${hr.p2p_24h} (24h)</div>
            ${
              // The XvB split line earns its header slot only while donation is on — off, it's a
              // permanent row of zeros advertising a feature the operator turned off.
              state.xvb_calc && state.xvb_calc.enabled
                ? html`<div class=${"text-xs mt-xs " + cVar(hr.xvb_variant)}>XvB (routed): ${hr.xvb_routed_1h} (1h) / ${hr.xvb_routed_24h} (24h)</div>`
                : null
            }
        </div>
    </div>`;
}

export { Header };
