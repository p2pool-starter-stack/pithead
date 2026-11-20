import json
import sys

import requests

from mining_dashboard.helper.http import bounded_get, proxy_map
from mining_dashboard.service.notify.healthchecks import _failure_class


def main():
    request = json.load(sys.stdin)
    proxy = request["proxy"]
    proxies = proxy_map(proxy)
    try:
        resp = bounded_get(
            request["url"],
            timeout=request["timeout"],
            deadline=request["deadline"],
            proxies=proxies,
        )
        out = {"status": resp.status_code}
    except requests.RequestException as e:
        out = {"reason": _failure_class(e, bool(proxy)), "name": type(e).__name__}
    except Exception as e:
        out = {"reason": "connect", "name": type(e).__name__}
    sys.stdout.write(json.dumps(out))


if __name__ == "__main__":
    main()
