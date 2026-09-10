import { html } from "../app/preact.mjs";
import { classifyMoneroAddress, pathGet, telegramPairReady } from "../config/configsync.mjs";
import { NodeProbeProgress, NodeProbeReport } from "../network/nodeprobe.mjs";
import { InstallSection } from "./stages.mjs";
import * as failure from "./wizardfailure.mjs";
import { MachineName } from "./wizardhostname.mjs";
import { TariSection, tariAnswer, XvbField } from "./wizardmining.mjs";
import { Err, Field, Note } from "./wizardparts.mjs";

const FIELDS = {
  moneroWallet: { path: "monero.wallet_address" },
  tariWallet: { path: "tari.wallet_address" },
  moneroMode: { path: "monero.mode" },
  prune: { path: "monero.prune" },
  moneroRemoteHost: { path: "monero.remote.host" },
  moneroRemoteRpc: { path: "monero.remote.rpc_port" },
  moneroRemoteZmq: { path: "monero.remote.zmq_port" },
  moneroUser: { path: "monero.node_username" },
  moneroPass: { path: "monero.node_password" },
  tariMode: { path: "tari.mode" },
  tariRemoteHost: { path: "tari.remote.host" },
  tariRemoteGrpc: { path: "tari.remote.grpc_port" },
  pool: { path: "p2pool.pool" },
  localMiner: { path: "local_miner.enabled" },
  xvb: { path: "xvb.enabled" },
  clearnetSync: { path: "monero.clearnet_initial_sync" },
  healthchecks: { path: "healthchecks.ping_url" },
  telegramToken: { path: "telegram.bot_token" },
  telegramChat: { path: "telegram.chat_id" },
  timezone: { path: "dashboard.timezone" },
  dashPassword: { path: "dashboard.auth.password" },
};

const TIMEZONES = [
  "auto",
  "UTC",
  "America/New_York",
  "America/Chicago",
  "America/Denver",
  "America/Los_Angeles",
  "America/Sao_Paulo",
  "Europe/London",
  "Europe/Berlin",
  "Europe/Warsaw",
  "Africa/Johannesburg",
  "Asia/Dubai",
  "Asia/Kolkata",
  "Asia/Singapore",
  "Asia/Tokyo",
  "Australia/Sydney",
];

export function renderSetup(app) {
  if (app.state.restoreMode) return app.renderRestore();
  const { cfg, error, jsonText, jsonError } = app.state;
  const v = (name) => pathGet(cfg, FIELDS[name].path);
  const on = (name) => app.edit(FIELDS[name].path);
  const addr = classifyMoneroAddress(v("moneroWallet"));
  const tg = telegramPairReady(v("telegramToken"), v("telegramChat"));
  const remoteMonero = v("moneroMode") === "remote";
  const tariMode = tariAnswer(v("tariMode"));
  const { installer, disks, chosen, confirm, wipe, dataWiped } = app.state;
  // The select is stored for a rig and read out of the config for the two coordinators.
  const role = app.state.role || (v("localMiner") ? "both" : "pithead");
  const rig = role === "rig";
  // Keep-everything reinstall: the machine's settings, wallets, login and chains all survive,
  // so there is nothing to ask — the config half of the page would collect answers the
  // machine will ignore (its preserved config wins). Only the disk half renders.
  const pickedState = (disks.find((d) => d.name === chosen) || {}).state;
  // Progressive disclosure: the DISK decides what gets asked (keep = nothing, keep-chains =
  // a trimmed form, fresh = everything), so until one is chosen the page asks only that.
  // The rig role's "usb" target counts as picked: running from the stick is a full answer.
  const diskPicked = !installer || Boolean(pickedState) || chosen === "usb";
  const keepEverything = installer && pickedState === "pithead-with-data" && wipe === "keep";
  return html`<div class="card">
        <p>${
          installer && !diskPicked
            ? rig
              ? html`Choose where this rig runs — one of the disks, or straight from this USB
                stick. The rest of the page appears once you pick.`
              : html`Choose the disk to install onto — what happens next depends on what is
              already on it, so the rest of the page appears once you pick.`
            : keepEverything
              ? html`This disk keeps everything — settings, wallets, dashboard login and the
              synced chains. Only the system is replaced, so there is nothing to configure:
              the machine comes back exactly as it was, on a fresh install.`
              : rig
                ? html`A rig needs almost nothing: where the pool is, and what to call this
                machine. It mines toward a Pithead and appears in that machine's dashboard.`
                : installer
                  ? html`Choose the disk to install onto and answer the questions below — the
                machine validates everything, shows you the login to save, and only then erases
                the disk. After it switches itself off, remove the stick and power it on: it
                provisions itself with exactly this configuration.`
                  : html`Only the answers that cannot be guessed for you. Everything else keeps
                its documented default and stays editable from the dashboard.`
        }</p>
        ${
          dataWiped.recovery &&
          html`<p class="c-bad">This machine's data area could not be read and was reinitialized
          on ${dataWiped.when} — the wallets, node identity and synced chains that were on it are
          gone. If you have a backup, restore it below instead of setting up as a fresh machine.</p>`
        }
        <p><button type="button" class="wizard-link"
            onClick=${() => app.setState({ restoreMode: true, error: "" })}>
            Restoring an existing Pithead? Upload its backup instead.</button></p>
        <${Err}>${error}<//>
        ${app.state.probing && html`<${NodeProbeProgress} config=${cfg} />`}
        <${NodeProbeReport} report=${app.state.nodeProbe}>Setup does not continue while a
        check is failing. Correct the address below and submit again.<//>
        <${failure.ConfigChanges} changes=${app.state.configChanges} />
        <form onSubmit=${app.submit}>
            <${Field} label="What is this machine?">
                <select value=${role} onChange=${app.setRole}>
                    <option value="pithead">Pithead</option>
                    <option value="both">Pithead + RigForge</option>
                    <option value="rig">RigForge</option>
                </select>
            <//>
            <${Note}>A Pithead coordinates the mine — nodes, pool and dashboard. A RigForge rig
            only mines, pointed at a Pithead. The middle choice is a Pithead that also mines
            with its own CPU.<//>
            ${
              installer &&
              html`<${InstallSection} disks=${disks} chosen=${chosen} confirm=${confirm}
                wipe=${wipe} allowStick=${rig}
                onPick=${(e) => app.setState({ chosen: e.target.value, wipe: "keep" })}
                onConfirm=${(e) => app.setState({ confirm: e.target.value })}
                onWipe=${(e) => app.setState({ wipe: e.target.value })} />`
            }
            ${diskPicked && !keepEverything && rig && app.renderRigFields()}
            ${diskPicked && !keepEverything && !rig && html`<${MachineName} cfg=${cfg} edit=${app.edit} />`}
            ${
              diskPicked &&
              !keepEverything &&
              !rig &&
              html`<h3>Payout address</h3>
            <${Note}>Paste it — it is far too long to type, and a typo pays a stranger.<//>
            <${Field} label="Monero payout address">
                <input class="wizard-mono" value=${v("moneroWallet") || ""} onInput=${on("moneroWallet")}
                    autocomplete="off" autocapitalize="off" spellcheck=${false}
                    placeholder="4… (95 characters)" required />
            <//>
            <p class=${addr.kind === "ok" || addr.kind === "empty" || addr.kind === "partial" ? "text-muted" : "c-bad"}>
                ${addr.message}
            </p>

            <h3>Monero node</h3>
            <${Field} label="Where does Monero data come from?">
                <select value=${remoteMonero ? "remote" : "local"} onChange=${on("moneroMode")}>
                    <option value="local">Run the bundled node on this machine (default)</option>
                    <option value="remote">Use a Monero node I already run</option>
                </select>
            <//>
            ${
              remoteMonero
                ? html`<div class="wizard-when">
                    <${Field} label="Node host">
                        <input value=${v("moneroRemoteHost") || ""} onInput=${on("moneroRemoteHost")}
                            placeholder="192.168.1.10 or my-node.local" autocomplete="off" spellcheck=${false} />
                    <//>
                    <${Field} label="RPC port">
                        <input value=${v("moneroRemoteRpc") ?? 18081} onInput=${on("moneroRemoteRpc")}
                            inputmode="numeric" pattern="[0-9]+" />
                    <//>
                    <${Field} label="ZMQ port">
                        <input value=${v("moneroRemoteZmq") ?? 18083} onInput=${on("moneroRemoteZmq")}
                            inputmode="numeric" pattern="[0-9]+" />
                    <//>
                    <${Field} label="Node username (blank if none)">
                        <input value=${v("moneroUser") || ""} onInput=${on("moneroUser")} autocomplete="off" />
                    <//>
                    <${Field} label="Node password">
                        <input type="password" value=${v("moneroPass") || ""} onInput=${on("moneroPass")}
                            autocomplete="new-password" />
                    <//>
                </div>`
                : null
            }

            <${TariSection} answer=${tariMode} v=${v} on=${on} />


            <h3>Mining</h3>
            <${Field} label="P2Pool sidechain">
                <select value=${v("pool") || "mini"} onChange=${on("pool")}>
                    <option value="mini">mini — right for almost every home rig (default)</option>
                    <option value="nano">nano — a single low-power rig</option>
                    <option value="main">main — only for very large hashrate</option>
                </select>
            <//>
            <${Note}>The sidechains are sized by hashrate so miners find shares at a similar
            cadence. Too large a tier means waiting days between shares; it costs nothing to
            change later.<//>
            <${Field} label="Mine on this machine too?">
                <select value=${String(v("localMiner") ?? false)} onChange=${on("localMiner")}>
                    <option value="false">No — this box only coordinates the miners</option>
                    <option value="true">Yes — this machine also mines with its own CPU (built-in RigForge, default)</option>
                </select>
            <//>
            ${
              v("localMiner") === true &&
              html`<${Note}>Nothing to install: the machine carries its own RigForge miner,
                pointed at its own pool. It starts by itself once the stack is up and appears
                in the dashboard's Workers view. Mining tunes the whole box for hashrate —
                CPU governor, memory reservations — which is exactly what a dedicated
                appliance is for.<//>`
            }
            <${XvbField} v=${v} on=${on} />

            <h3>First sync</h3>
            <${Field} label="Downloading the chain the first time">
                <select value=${String(v("clearnetSync") ?? false)} onChange=${on("clearnetSync")}>
                    <option value="false">Private, over Tor — takes days</option>
                    <option value="true">Faster, over the open internet, then Tor afterwards — takes hours</option>
                </select>
            <//>


            <h3>Dashboard login</h3>
            <${Field} label="How should the dashboard be protected?">
                <select value=${app.state.authMode} onChange=${(e) => app.setState({ authMode: e.target.value })}>
                    <option value="auto">Generate a strong password for me (recommended)</option>
                    <option value="set">Let me choose the password</option>
                    <option value="none">No login at all</option>
                </select>
            <//>
            ${
              app.state.authMode === "set"
                ? html`<div class="wizard-when">
                    <${Field} label="Password (8+ characters)">
                        <input type="password" value=${v("dashPassword") || ""}
                            onInput=${on("dashPassword")} autocomplete="new-password" minlength="8" />
                    <//>
                <//>`
                : app.state.authMode === "none"
                  ? html`<p class="c-bad">Anyone on this network will be able to open the
                    dashboard — it shows your payout addresses and hashrate. Only choose this on a
                    network you fully control, and never with the Tor onion enabled.</p>`
                  : html`<${Note}>A 32-character password is generated on the machine and shown
                    to you on the next screen.<//>`
            }

            <h3>Alerts <span class="text-muted">(optional — skip if you are not sure)</span></h3>
            <${Field} label="Telegram bot token">
                <input value=${v("telegramToken") || ""} onInput=${on("telegramToken")}
                    autocomplete="off" spellcheck=${false} placeholder="123456:ABC-DEF…" />
            <//>
            <${Field} label="Telegram chat ID">
                <input value=${v("telegramChat") || ""} onInput=${on("telegramChat")}
                    autocomplete="off" spellcheck=${false} placeholder="987654321" />
            <//>
            ${tg.partial && html`<p class="c-bad">Telegram needs both fields, or leave both blank.</p>`}

            <details>
                <summary><strong>Advanced</strong> — the exact configuration, every key and default</summary>
                <${Note}>Everything here already has a sane default — the machine runs fine
                untouched. Change these only if you know you need to.<//>
                ${
                  !remoteMonero &&
                  html`<${Field} label="Chain size">
                    <select value=${String(v("prune") ?? true)} onChange=${on("prune")}>
                        <option value="true">Pruned — about 120 GB (default, mines exactly the same)</option>
                        <option value="false">Full — about 320 GB (only if you need the whole chain)</option>
                    </select>
                <//>
                ${
                  tariMode !== "off" &&
                  html`<${Note}>A local Tari node adds about 170 GB on top. Under roughly 350 GB
                    of disk, pruned Monero plus a ${" "}<em>remote</em>${" "}Tari node is the
                    combination that fits.<//>`
                }`
                }
                <${Field} label="Healthchecks.io ping URL">
                    <input value=${v("healthchecks") || ""} onInput=${on("healthchecks")}
                        autocomplete="off" spellcheck=${false} placeholder="https://hc-ping.com/your-uuid" />
                <//>
                <${Note}>Tells you when this machine goes ${" "}<em>silent</em>${" "}— a power cut
                or a crash, which the machine itself cannot report.<//>
                <${Field} label="Time zone">
                    <input value=${v("timezone") || "auto"} onInput=${on("timezone")} list="wizard-tzs"
                        autocomplete="off" />
                <//>
                <datalist id="wizard-tzs">${TIMEZONES.map((t) => html`<option value=${t} />`)}</datalist>
                <${Note}><code>auto</code>${" "}uses this machine's own setting — for dashboard
                timestamps and the daily summary.<//>

                <${Note}>This is what the machine will run. Editing a field above updates it;
                editing it here directly wins. Keys still at their documented default are not
                written to disk, so this machine keeps receiving improved defaults from future
                updates — the effective configuration is identical either way.<//>
                <textarea class="wizard-json wizard-mono" value=${jsonText} onInput=${app.editJson}
                    spellcheck=${false}></textarea>
                <${Err}>${jsonError}<//>
            </details>`
            }

            ${
              diskPicked &&
              html`<button type="submit" class="btn-toggle active" disabled=${(!rig && !!jsonError) || app.state.submitting}>
                ${
                  app.state.submitting
                    ? app.state.probing
                      ? "Reaching remote nodes…"
                      : "Validating…"
                    : keepEverything
                      ? "Reinstall the system — keep everything"
                      : installer
                        ? chosen === "usb"
                          ? "Validate, then save to this stick"
                          : "Validate, then install"
                        : "Apply"
                }</button>`
            }
        </form>
    </div>`;
}
