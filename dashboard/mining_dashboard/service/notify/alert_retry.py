import asyncio
import time

RETRY_MAX_AGE_S = 3600
RETRY_FIRST_S = 30
RETRY_EVERY_S = 300
RETRY_MAX_PENDING = 50


class AlertOutbox:
    def __init__(self):
        self.pending = []
        self._wait = 0
        self._retry_at = 0.0

    async def send(self, alerts, event_sinks):
        now = time.monotonic()
        queue = [p for p in self.pending if now - p[2] < RETRY_MAX_AGE_S]
        if not alerts and now < self._retry_at:
            self.pending = queue
            return
        queue += [(evt, text, now) for evt, text in alerts]
        failed, kept = set(), []
        for evt, text, since in queue:
            sinks = event_sinks(evt)
            delivered = False
            for sink in sinks:
                if id(sink) in failed:
                    continue
                if await asyncio.to_thread(sink.send, text, evt) is False:
                    failed.add(id(sink))
                else:
                    delivered = True
            if sinks and not delivered:
                kept.append((evt, text, since))
        self.pending = kept[-RETRY_MAX_PENDING:]
        self._wait = min(max(self._wait * 2, RETRY_FIRST_S), RETRY_EVERY_S) if kept else 0
        self._retry_at = now + self._wait
