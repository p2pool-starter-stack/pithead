export const DONATION_LEVELS = [0, 1, 2, 5];

export function timeSentence(percent) {
  if (!percent) return "Nothing is donated.";
  return `${percent} ${percent === 1 ? "minute" : "minutes"} in every 100 minutes, roughly ${Math.ceil((1440 * percent) / 100)} minutes a day.`;
}

export function dailyCost(percent, hashrate, coeffDay) {
  if (!Number.isFinite(hashrate) || hashrate <= 0 || !(coeffDay > 0)) return null;
  const xmr = (hashrate * coeffDay * percent) / 100;
  return xmr > 0 && xmr < 1e-8 ? "less than 0.00000001 XMR a day" : `${xmr.toFixed(8)} XMR a day`;
}

export function rigDonation(worker, rigConfig) {
  const reported = Number.isInteger(worker?.donate_level) ? worker.donate_level : null;
  const configured = Number.isInteger(rigConfig?.DONATION) ? rigConfig.DONATION : null;
  if (reported === null)
    return { reported, configured, text: "Own donation: unknown", mismatch: null };
  const text = `${reported} % reported by the miner`;
  if (configured === null || configured === reported)
    return { reported, configured, text, mismatch: null };
  const next =
    reported > configured ? "needs a RigForge update to lower" : "applies after the miner restarts";
  return {
    reported,
    configured,
    text,
    mismatch: `Configured ${configured} %, running ${reported} %: ${next}.`,
  };
}

export function fleetLine(donation) {
  if (!donation?.rigs) return "XMRig developers: no rigs reported.";
  const unknown = donation.unknown
    ? ` ${donation.unknown} of ${donation.rigs} rigs report no level; their own donation (usually 1 %) may still apply.`
    : "";
  if (!donation.available) return `XMRig developers: combined share unavailable.${unknown}`;
  return donation.donating
    ? `XMRig developers: ${donation.percent} % of hashrate on ${donation.donating} of ${donation.rigs} rigs.${unknown}`
    : `XMRig developers: off on all ${donation.rigs} rigs.${unknown}`;
}
