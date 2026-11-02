import json
import logging
import re
import uuid
from datetime import UTC, datetime

logger = logging.getLogger("TorHeal")


class TorLifecycleMixin:
    async def _tor_begin(self, action):
        identity = "unavailable"
        operation = "unavailable"
        try:
            if action in {"stop", "recover"} or not getattr(self, "_receipt_operation", None):
                self._receipt_operation = uuid.uuid4().hex
            operation = self._receipt_operation
            identify = getattr(self._docker, "identity", None)
            if identify is not None:
                identity = await identify(self.CONTAINER)
            if not isinstance(identity, str) or not re.fullmatch(r"[0-9a-f]{64}", identity):
                identity = "unavailable"
        except Exception:
            identity = "unavailable"
        self._tor_receipt(operation, identity, action, "requested")
        return operation, identity

    async def _tor_call(self, action, **kwargs):
        operation = "unavailable"
        try:
            if action == "stop" or not getattr(self, "_receipt_operation", None):
                self._receipt_operation = uuid.uuid4().hex
            operation = self._receipt_operation
        except Exception:
            operation = "unavailable"
        identity = "unavailable"
        requested = False

        def identified(value):
            nonlocal identity, requested
            if isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value):
                identity = value
            self._tor_receipt(operation, identity, action, "requested")
            requested = True

        result = False
        try:
            result = await getattr(self._docker, action)(
                self.CONTAINER, on_identity=identified, **kwargs
            )
            return result
        finally:
            if not requested:
                identified("unavailable")
            self._tor_receipt(operation, identity, action, "confirmed" if result else "unconfirmed")

    def _tor_recovery_result(self, result):
        operation, identity = getattr(self, "_host_receipt", ("unavailable", "unavailable"))
        self._tor_receipt(operation, identity, "recover", result)

    @staticmethod
    def _tor_receipt(operation, identity, action, result) -> None:
        try:
            logger.info(
                "pithead-tor-lifecycle %s",
                json.dumps(
                    {
                        "timestamp": datetime.now(UTC).isoformat(),
                        "caller": "tor-heal",
                        "operation": operation,
                        "container": identity,
                        "action": action,
                        "result": result,
                    },
                    separators=(",", ":"),
                ),
            )
        except Exception:
            return
