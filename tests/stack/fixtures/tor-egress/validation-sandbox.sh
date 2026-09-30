# shellcheck shell=bash
# The shared validation sandbox has no kernel. Keep both rule sets as live readback, so an
# active first-sync apply and a LAN bind change must prove their own installed rules.
CNFW_DIR="${1:-$V}"
: >"$CNFW_DIR/fw-rules"
: >"$CNFW_DIR/fw-lan-rules"
cat >"$CNFW_DIR/bin/sudo" <<'SUDO'
#!/usr/bin/env bash
[ "${1:-}" != -n ] || shift
case "${1:-}" in iptables | iptables-save | iptables-restore) exec "$@" ;; esac
exit 0
SUDO
cat >"$CNFW_DIR/bin/iptables-save" <<'SAVE'
#!/usr/bin/env bash
printf '*filter\n-N DOCKER-USER\n'
cat "${0%/*}/../fw-rules"
cat "${0%/*}/../fw-lan-rules"
printf 'COMMIT\n'
SAVE
cat >"$CNFW_DIR/bin/iptables-restore" <<'RESTORE'
#!/usr/bin/env bash
txn="${0%/*}/../fw-transaction"
cat >"$txn"
if grep -q '^:PITHEAD-LAN ' "$txn"; then
    awk '/^-A PITHEAD-LAN / {print} /^-I DOCKER-USER [0-9]+ .*pithead-lan-guard/ {sub(/^-I DOCKER-USER [0-9]+ /, "-A DOCKER-USER "); print}' "$txn" >"${0%/*}/../fw-lan-rules"
else
    awk '/^-I DOCKER-USER [0-9]+ / {sub(/^-I DOCKER-USER [0-9]+ /, "-A DOCKER-USER "); print}' "$txn" >"${0%/*}/../fw-rules"
fi
RESTORE
cat >"$CNFW_DIR/bin/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
"-S DOCKER-USER") printf '%s\n' '-N DOCKER-USER'; cat "${0%/*}/../fw-rules"; grep '^-A DOCKER-USER ' "${0%/*}/../fw-lan-rules" || : ;;
"-S PITHEAD-LAN") printf '%s\n' '-N PITHEAD-LAN'; grep '^-A PITHEAD-LAN ' "${0%/*}/../fw-lan-rules" ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
IPT
chmod +x "$CNFW_DIR/bin/"{sudo,iptables,iptables-save,iptables-restore}
