import os

PROBE_URL = os.environ.get("TOR_HEAL_PROBE_URL") or "https://www.google.com/generate_204"
SECOND_PROBE_URL = (
    os.environ.get("TOR_HEAL_SECOND_PROBE_URL") or "https://www.cloudflare.com/cdn-cgi/trace"
)
