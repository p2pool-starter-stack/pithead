export const ESTIMATES_PENDING =
  "Return estimates are unavailable while P2Pool's dynamic window support is being completed. No payout date is predicted.";

export function payoutRows(state) {
  return ["monero", ...(state?.tari?.active === true ? ["tari"] : [])]
    .flatMap((chain) => {
      const rows = state?.payouts?.[chain];
      if (!Array.isArray(rows)) return [];
      return rows
        .filter(
          (row) =>
            Number.isFinite(row.x) &&
            row.x > 0 &&
            row.x <= 8.64e15 &&
            Number.isFinite(row.amount) &&
            row.amount > 0,
        )
        .map((row) => ({
          chain,
          timestamp: row.x,
          amount: row.amount / (chain === "monero" ? 1e12 : 1e6),
          unit: chain === "monero" ? "XMR" : "XTM",
        }));
    })
    .sort((a, b) => b.timestamp - a.timestamp);
}

export function trackingNotice(summary) {
  if (summary?.enabled !== true)
    return "Tracking may be incomplete: no view-only tracking is enabled.";
  if (summary.address_match === false)
    return "Tracking may be incomplete: the payout wallet does not match the configured address.";
  if (summary.reachable === false || summary.down === true)
    return "Tracking may be incomplete: the payout wallet is unreachable or its scan has not answered.";
  if (summary.reachable !== true)
    return "Tracking may be incomplete: the payout wallet's status is unknown.";
  if (summary.partial?.["30d"] !== false) return "Tracking may be incomplete for the last 30 days.";
  return null;
}

export function xvbLine(state, connected) {
  const enabled = state?.xvb_calc?.enabled;
  if (typeof enabled !== "boolean")
    return "XvB status not reported; donated percentage unavailable.";
  if (!enabled) return "XvB off · current donated percentage 0%.";
  const latest = Array.isArray(state.xvb_history)
    ? [...state.xvb_history].sort((a, b) => b.x - a.x)[0]
    : null;
  if (
    !connected ||
    !latest ||
    !Number.isFinite(latest.x) ||
    latest.x <= 0 ||
    latest.x > 8.64e15 ||
    !Number.isFinite(latest.donation_fraction) ||
    latest.donation_fraction < 0 ||
    latest.donation_fraction > 1
  )
    return "XvB on · donated percentage unavailable or stale.";
  return `XvB on · ${Number((latest.donation_fraction * 100).toFixed(1))}% routed to XvB, recorded ${new Date(latest.x).toLocaleString()}.`;
}
