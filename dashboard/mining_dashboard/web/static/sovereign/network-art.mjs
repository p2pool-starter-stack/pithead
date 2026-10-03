import { html } from "../app/preact.mjs";

export function NetworkArt() {
  return html`
    <figure class="sov-network-art">
      <svg viewBox="0 0 620 430" role="img" aria-labelledby="sov-network-title sov-network-desc">
        <title id="sov-network-title">Monero network sphere</title>
        <desc id="sov-network-desc">A decorative wireframe globe surrounding the Monero mark.</desc>
        <defs>
          <radialGradient id="sov-glow">
            <stop offset="0" stop-color="#ffb164" stop-opacity=".32" />
            <stop offset=".5" stop-color="#ff782d" stop-opacity=".12" />
            <stop offset="1" stop-color="#ff782d" stop-opacity="0" />
          </radialGradient>
          <linearGradient id="sov-mark" x1="0" y1="0" x2="0" y2="1">
            <stop offset="0" stop-color="#ff963e" />
            <stop offset="1" stop-color="#f15a24" />
          </linearGradient>
          <filter id="sov-node-glow" x="-200%" y="-200%" width="500%" height="500%">
            <feGaussianBlur stdDeviation="5" result="blur" />
            <feMerge><feMergeNode in="blur" /><feMergeNode in="SourceGraphic" /></feMerge>
          </filter>
        </defs>
        <ellipse class="sov-art-glow" cx="310" cy="215" rx="285" ry="205" fill="url(#sov-glow)" />
        <g class="sov-art-grid" fill="none">
          <ellipse cx="310" cy="215" rx="214" ry="174" />
          <ellipse cx="310" cy="215" rx="214" ry="78" />
          <ellipse cx="310" cy="215" rx="214" ry="132" />
          <ellipse cx="310" cy="215" rx="88" ry="174" />
          <ellipse cx="310" cy="215" rx="150" ry="174" />
          <path d="M96 215 172 94l138-53 139 53 75 121-75 122-139 52-138-52Z" />
          <path d="m126 142 111 38 73-139 74 139 110-38M126 288l111-38 73 139 74-139 110 38" />
          <path d="m172 94 65 86-65 157M449 94l-65 86 65 157M237 180l73 35 74-35M237 250l73-35 74 35" />
        </g>
        <g class="sov-art-links" fill="none">
          <path d="M96 215 172 94 237 180 126 288 237 250 310 389" />
          <path d="M310 41 384 180 494 142 524 215 449 337 384 250 310 389" />
          <path d="m172 337 138-122 139 122M172 94l138 121L449 94" />
        </g>
        <g class="sov-art-nodes" filter="url(#sov-node-glow)">
          <circle cx="96" cy="215" r="3" /><circle cx="126" cy="142" r="3" />
          <circle cx="172" cy="94" r="4" /><circle cx="172" cy="337" r="3" />
          <circle cx="237" cy="180" r="3" /><circle cx="237" cy="250" r="3" />
          <circle cx="310" cy="41" r="4" /><circle cx="310" cy="389" r="4" />
          <circle cx="384" cy="180" r="3" /><circle cx="384" cy="250" r="3" />
          <circle cx="449" cy="94" r="4" /><circle cx="449" cy="337" r="3" />
          <circle cx="494" cy="142" r="3" /><circle cx="524" cy="215" r="4" />
        </g>
        <g class="sov-monero" transform="translate(251 156)">
          <circle cx="59" cy="59" r="57" />
          <path fill="url(#sov-mark)" d="M2 59a57 57 0 0 1 114 0v19H98V42L59 81 20 42v36H2Z" />
          <path d="m20 42 39 39 39-39v19L59 100 20 61Z" />
        </g>
      </svg>
      <figcaption>Network illustration</figcaption>
    </figure>`;
}
