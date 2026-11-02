import asyncio
import fcntl
import json
import logging
import re

import aiohttp

from mining_dashboard.config.config import DOCKER_CONTROL_URL, DOCKER_PROXY_URL, DOCKER_TIMEOUT
from mining_dashboard.helper.http import bounded_read

logger = logging.getLogger("DockerControl")


class DockerControl:
    """
    Narrow start/stop control of stack containers (Issue #31).

    Goes through a dedicated `docker-control` socket proxy whose ruleset allows exactly
    `POST /containers/<id>/{start,stop}` and nothing else — not the read-only `docker-proxy`
    the dashboard uses for stats/logs. (tecnativa/docker-socket-proxy v0.5.0 denies all POST
    unless POST=1, and POST=1 on the read proxy would also open create/kill/exec via its
    CONTAINERS grant — so container control lives on its own minimal proxy instead.)

    Stopping (not pausing) is deliberate: a stopped container closes its published port,
    so miners get a clean disconnect and fail over to their backup pools; a paused one
    leaves the port open-but-dead and they stall instead.
    """

    def __init__(
        self, proxy_url=DOCKER_CONTROL_URL, timeout=DOCKER_TIMEOUT, lock_file="/pithead-lock"
    ):
        # aiohttp needs an http:// scheme even though the env var uses tcp://.
        base = proxy_url
        if base.startswith("tcp://"):
            base = base.replace("tcp://", "http://")
        self.base_url = base.rstrip("/")
        self.timeout = timeout
        self.lock_file = lock_file

    def _open_lock(self):
        lock = open(self.lock_file, "rb")
        return lock

    async def identity(self, container):
        try:
            base = DOCKER_PROXY_URL.replace("tcp://", "http://").rstrip("/")
            async with aiohttp.ClientSession() as session:
                async with session.get(f"{base}/containers/{container}/json", timeout=1) as resp:
                    if resp.status != 200:
                        return "unavailable"
                    payload = json.loads(await bounded_read(resp.content, max_bytes=65536))
                    identity = payload.get("Id")
                    if isinstance(identity, str) and re.fullmatch(r"[0-9a-f]{64}", identity):
                        return identity
        except Exception:
            return "unavailable"
        return "unavailable"

    async def _acquire_lock(self):
        lock = self._open_lock()
        try:
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    return lock
                except BlockingIOError:
                    await asyncio.sleep(0.1)
        except (OSError, asyncio.CancelledError):
            lock.close()
            raise

    async def stop(
        self, container, stop_timeout=10, quiet=False, request_timeout=None, on_identity=None
    ):
        return await self._post(
            f"/containers/{container}/stop",
            params={"t": stop_timeout},
            action="stop",
            container=container,
            quiet=quiet,
            request_timeout=request_timeout,
            on_identity=on_identity,
        )

    async def start(self, container, quiet=False, request_timeout=None, on_identity=None):
        return await self._post(
            f"/containers/{container}/start",
            params=None,
            action="start",
            container=container,
            quiet=quiet,
            request_timeout=request_timeout,
            on_identity=on_identity,
        )

    async def _post(
        self, path, params, action, container, quiet=False, request_timeout=None, on_identity=None
    ) -> bool:
        url = f"{self.base_url}{path}"
        try:
            lock = await self._acquire_lock()
        except OSError as e:
            logger.error(f"Container {container} {action} refused: pithead lock unavailable: {e}")
            return False
        try:
            if on_identity is not None:
                try:
                    on_identity(await self.identity(container))
                except Exception:
                    logger.debug("Container lifecycle identity observer unavailable")
            async with aiohttp.ClientSession() as session:
                async with session.post(
                    url, params=params, timeout=request_timeout or self.timeout
                ) as resp:
                    # 204 No Content = done; 304 Not Modified = already in that state
                    # (Docker's idempotent response) — both are success for us.
                    if resp.status in (204, 304):
                        log = logger.debug if quiet else logger.info
                        log(f"Container {container} {action}: ok (HTTP {resp.status})")
                        return True
                    # Bounded (#1360). The 200-char slice below only ever trimmed the LOG LINE —
                    # the whole body was buffered first, so an error response was the one path
                    # here that read without a limit.
                    raw = await bounded_read(resp.content, what=f"{container} {action} error")
                    body = raw.decode("utf-8", errors="replace")
                    logger.error(
                        f"Container {container} {action} failed: HTTP {resp.status} {body[:200]}"
                    )
                    return False
        except Exception as e:
            logger.error(f"Container {container} {action} error via {self.base_url}: {e}")
            return False
        finally:
            lock.close()
