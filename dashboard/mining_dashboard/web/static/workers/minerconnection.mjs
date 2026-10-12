import { Component, html } from "../app/preact.mjs";

export const ConnectionFields = ({ connection, visible, onReveal, onCopy, status }) => html`
  <p>Pool URL: <code>${connection.url}</code></p>
  ${
    !connection.password_set
      ? html`<p>No stratum password</p>`
      : html`<label>Stratum password
          <input readonly type=${visible ? "text" : "password"} value=${connection.password}
                 autocomplete="off" />
        </label>
        <button type="button" onClick=${onReveal}>${visible ? "Hide" : "Reveal"}</button>
        <button type="button" onClick=${onCopy}>Copy password</button>`
  }
  ${connection.tls && html`<p>TLS fingerprint: <code>${connection.fingerprint || "Unavailable — apply the configuration again."}</code></p>`}
  ${status && html`<p role="status">${status}</p>`}`;

export class MinerConnection extends Component {
  state = { connection: null, visible: false, status: "" };
  async load() {
    try {
      const res = await fetch("/api/miner-connection", { cache: "no-store" });
      if (!res.ok) throw new Error("connection details unavailable");
      this.setState({ connection: await res.json(), status: "" });
    } catch {
      this.setState({
        connection: null,
        visible: false,
        status: "Connection details unavailable. Retrying…",
      });
    }
  }
  componentDidMount() {
    this.load();
    this.timer = setInterval(() => this.load(), 30000);
  }
  componentWillUnmount() {
    clearInterval(this.timer);
  }
  copy = async () => {
    try {
      await navigator.clipboard.writeText(this.state.connection.password);
      this.setState({ status: "Password copied." });
    } catch {
      this.setState({ status: "Copy unavailable. Reveal the password and copy it manually." });
    }
  };
  render(_, { connection, visible, status }) {
    return html`<div class="card" id="connect-a-miner"><h2>Connect a miner</h2>
      ${
        connection
          ? html`<${ConnectionFields} connection=${connection} visible=${visible}
            onReveal=${() => this.setState({ visible: !visible })} onCopy=${this.copy} status=${status} />`
          : html`<p role="status">${status || "Loading connection details…"}</p>`
      }
    </div>`;
  }
}
