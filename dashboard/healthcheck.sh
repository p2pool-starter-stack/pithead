#!/bin/bash
exec 3<>"/dev/tcp/127.0.0.1/${DASHBOARD_HEALTH_PORT:-8000}" || exit 1
printf 'HEAD /api/state HTTP/1.0\r\nHost: 127.0.0.1\r\nX-Pithead-Proxy-Secret: %s\r\n\r\n' "${DASHBOARD_PROXY_SECRET:-}" >&3
read -r -t 5 _ status _ <&3 || exit 1
[[ $status == 2* ]]
