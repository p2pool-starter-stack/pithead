import asyncio
import threading
from concurrent.futures import ThreadPoolExecutor


class StateExecutor:
    def __init__(self):
        self._slots = threading.BoundedSemaphore(4)
        self._executor = ThreadPoolExecutor(max_workers=4, thread_name_prefix="go-state")

    async def run(self, function, *args, **kwargs):
        if not self._slots.acquire(blocking=False):
            raise RuntimeError("native state assembly busy")
        try:
            future = self._executor.submit(function, *args, **kwargs)
        except BaseException:
            self._slots.release()
            raise
        future.add_done_callback(lambda _future: self._slots.release())
        return await asyncio.wrap_future(future)

    async def close(self):
        await asyncio.to_thread(self._executor.shutdown, wait=True, cancel_futures=True)
