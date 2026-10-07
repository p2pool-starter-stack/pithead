import { html } from "./preact.mjs";

// Fetch cannot distinguish certificate distrust from a network or authentication failure.
export function ConnectionRecovery() {
  return html`<p>Retries have not restored the connection. Check that the machine is running and
    reachable. Reload this page or open the same dashboard address in a new tab to inspect any
    browser warning or login prompt.</p>
    <p>On an appliance, a changed network address can replace its certificate, even if the hostname
    you use stays the same. If the browser shows a certificate warning, compare the certificate's
    SHA-256 fingerprint with the current fingerprint on the appliance console. Stop if they do not
    match. Accept the replacement only after they match, then return to this tab; polling will
    reconnect when the dashboard is reachable. The browser does not tell this page which failure
    occurred.</p>`;
}
