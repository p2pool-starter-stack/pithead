export function rigFleet(count) {
  return Array.from({ length: count }, (_, index) => {
    const name = index % 10 === 3 ? "rig-dup" : `rig-${String(index).padStart(3, "0")}`;
    const offline = index % 7 === 5;
    const silent = index % 11 === 4;
    const managed = index % 3 !== 2;
    const behind = managed && index % 4 === 1;
    return {
      name,
      status: offline ? "offline" : "online",
      h60: offline || silent ? 0 : 1000 + index * 37,
      h15: offline || silent ? 0 : 1000 + index * 37,
      accepted: index * 3,
      accepted_str: String(index * 3),
      rejected: index % 2,
      rejected_str: String(index % 2),
      adopted: managed,
      api_ok: !silent,
      rigforge: managed ? { version: behind ? "0.9.0" : "1.0.0", chips: [] } : null,
      rigforge_update: behind ? { available: true, latest: "1.0.0", url: null } : null,
    };
  });
}
