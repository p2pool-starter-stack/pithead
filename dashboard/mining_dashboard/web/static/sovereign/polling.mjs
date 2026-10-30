export function createPolling({
  fetchFn,
  publish,
  schedule = setInterval,
  cancel = clearInterval,
}) {
  let snapshot = null;
  let inflight = false;
  let stopped = false;
  let controller;
  const tick = async () => {
    if (inflight || stopped) return;
    inflight = true;
    controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 25000);
    try {
      const response = await fetchFn(controller.signal);
      if (!response.ok) throw Object.assign(new Error(), { status: response.status });
      const next = await response.json();
      if (!next || typeof next !== "object" || Array.isArray(next)) throw new Error();
      snapshot = next;
      if (!stopped) publish({ snapshot, connected: true, sessionExpired: false });
    } catch (error) {
      if (!stopped) publish({ snapshot, connected: false, sessionExpired: error.status === 401 });
    } finally {
      clearTimeout(timeout);
      inflight = false;
    }
  };
  const timer = schedule(tick, 30000);
  return {
    tick,
    close() {
      stopped = true;
      controller?.abort();
      cancel(timer);
    },
  };
}
