: "${STACK_SUITE:?source via tests/stack/run.sh}"

echo "== serial getty: phantom 8250 ports are skipped =="
SERIAL_TEST="$SANDBOX/serial-getty"
mkdir -p "$SERIAL_TEST"
PORT_CHECK="$ROOT/os/overlay/pithead-serial-port-present"
GETTY_DROPIN="$ROOT/os/overlay/pithead-serial-getty.conf"
rc=0
"$PORT_CHECK" "$SERIAL_TEST/absent" || rc=$?
assert_rc "an absent tty type cannot start serial getty" "$rc" 1
printf '0\n' >"$SERIAL_TEST/type"
rc=0
"$PORT_CHECK" "$SERIAL_TEST/type" || rc=$?
assert_rc "an unbacked 8250 tty cannot start serial getty" "$rc" 1
printf '4\n' >"$SERIAL_TEST/type"
assert_rc "a real 16550A tty starts serial getty" "$("$PORT_CHECK" "$SERIAL_TEST/type"; echo $?)" 0
printf 'unknown\n' >"$SERIAL_TEST/type"
rc=0
"$PORT_CHECK" "$SERIAL_TEST/type" || rc=$?
assert_rc "an invalid tty type cannot pass as a real port" "$rc" 1

assert_rc "the image copies the port check" "$(grep -Fq 'COPY os/overlay/pithead-serial-port-present /usr/local/sbin/pithead-serial-port-present' "$ROOT/os/rootfs/Dockerfile"; echo $?)" 0
assert_rc "the image installs the serial getty drop-in" "$(grep -Fq 'COPY os/overlay/pithead-serial-getty.conf /etc/systemd/system/serial-getty@ttyS0.service.d/override.conf' "$ROOT/os/rootfs/Dockerfile"; echo $?)" 0
assert_eq "the unit checks the same sysfs type" "$(sed -n 's/^ExecCondition=//p' "$GETTY_DROPIN")" \
    '/usr/local/sbin/pithead-serial-port-present /sys/class/tty/ttyS0/type'
assert_eq "a skipped condition does not restart" "$(sed -n 's/^Restart=//p' "$GETTY_DROPIN")" on-failure
assert_eq "clean real getty exits still respawn a login prompt" \
    "$(sed -n 's/^RestartForceExitStatus=//p' "$GETTY_DROPIN")" '0 SIGHUP SIGINT SIGTERM SIGPIPE'
