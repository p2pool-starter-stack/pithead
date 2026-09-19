"""Send one operator-requested test message through the configured alert sinks."""

import sys

from mining_dashboard.service.notify.alert_service import build_default_notifier
from mining_dashboard.service.notify.notify_sinks import NtfySink, WebhookSink, config_sinks

TEST_MESSAGE = "Pithead test alert — notification delivery check."
TEST_EVENT = "test_alert"


def _send(label, sink, output):
    if not sink.enabled:
        print(f"{label}: not configured", file=output)
        return True
    if sink.send(TEST_MESSAGE, TEST_EVENT):
        print(f"{label}: PASS", file=output)
        return True
    print(f"{label}: FAIL ({sink.last_failure or 'unknown error'})", file=output)
    return False


def run_test_alert(notifier=None, sinks=None, output=None):
    """Send the test message and return whether every configured notification sink passed."""
    output = output or sys.stdout
    notifier = notifier if notifier is not None else build_default_notifier()
    sinks = list(sinks) if sinks is not None else config_sinks()
    passed = _send("Telegram", notifier, output)

    webhooks = [sink for sink in sinks if isinstance(sink, WebhookSink)]
    if webhooks:
        for index, sink in enumerate(webhooks, 1):
            label = f"Webhook {index}" if len(webhooks) > 1 else "Webhook"
            passed = _send(label, sink, output) and passed
    else:
        print("Webhook: not configured", file=output)

    ntfy = next((sink for sink in sinks if isinstance(sink, NtfySink)), None)
    if ntfy is None:
        print("ntfy: not configured", file=output)
    else:
        passed = _send("ntfy", ntfy, output) and passed

    print("Healthchecks: excluded — a ping moves the dead-man switch.", file=output)
    return passed


if __name__ == "__main__":
    raise SystemExit(0 if run_test_alert() else 1)
