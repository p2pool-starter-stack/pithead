#!/bin/bash
exec python3 -c 'import os, urllib.request as u; u.urlopen(u.Request("http://127.0.0.1:8000/api/state", method="HEAD", headers={"X-Pithead-Proxy-Secret": os.environ.get("DASHBOARD_PROXY_SECRET", "")}), timeout=5)'
