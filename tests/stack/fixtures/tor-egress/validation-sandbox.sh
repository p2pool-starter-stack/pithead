# shellcheck shell=bash
# The shared validation sandbox has no kernel. Keep the transaction's inserted rules as its live
# readback, so an active first-sync apply must install its scoped ACCEPT before the DROP.
CNFW_DIR="${1:-$V}"
: >"$CNFW_DIR/fw-rules"
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
printf 'COMMIT\n'
SAVE
cat >"$CNFW_DIR/bin/iptables-restore" <<'RESTORE'
#!/usr/bin/env bash
awk '/^-I DOCKER-USER [0-9]+ / {sub(/^-I DOCKER-USER [0-9]+ /, "-A DOCKER-USER "); print}' >"${0%/*}/../fw-rules"
RESTORE
cat >"$CNFW_DIR/bin/iptables" <<'IPT'
#!/usr/bin/env bash
case "$*" in
"-S FORWARD") echo '-A FORWARD -j DOCKER-USER' ;;
"-S DOCKER-USER") printf '%s\n' '-N DOCKER-USER'; cat "${0%/*}/../fw-rules" ;;
"-S") echo '-P FORWARD ACCEPT' ;;
esac
IPT
chmod +x "$CNFW_DIR/bin/"{sudo,iptables,iptables-save,iptables-restore}
