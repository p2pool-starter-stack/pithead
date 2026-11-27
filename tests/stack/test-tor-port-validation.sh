# shellcheck shell=bash
: "${STACK_SUITE:?source this fragment through tests/stack/run.sh}"

echo "== unit: Tor refuses unsupported P2Pool ports before rendering (#2936) =="
TOR_ENTRY="${TOR_ENTRY:-$ROOT/build/tor/entrypoint.sh}"
tor_port_dir=""
mk_tmpdir tor_port_dir
printf '#!/bin/sh\nprintf launched >"$TOR_LAUNCH_MARKER"\n' >"$tor_port_dir/tor"
chmod +x "$tor_port_dir/tor"
for invalid_port in 0 65536 37891 nano '37888 '; do
    rm -f "$tor_port_dir/torrc" "$tor_port_dir/launched"
    if port_output="$(PATH="$tor_port_dir:$PATH" P2POOL_PORT="$invalid_port" \
        TORRC_TEMPLATE="$ROOT/build/tor/torrc.template" TORRC_OUT="$tor_port_dir/torrc" \
        TOR_LAUNCH_MARKER="$tor_port_dir/launched" sh "$TOR_ENTRY" 2>&1)"; then
        port_status=0
    else
        port_status=$?
    fi
    assert_rc "Tor rejects unsupported port [$invalid_port] (#2936)" "$port_status" 1
    assert_contains "Tor diagnoses unsupported port [$invalid_port] (#2936)" "$port_output" "invalid P2POOL_PORT"
    assert_eq "Tor renders nothing for unsupported port [$invalid_port] (#2936)" \
        "$(test -e "$tor_port_dir/torrc" && echo rendered || echo absent)" absent
    assert_eq "Tor never launches for unsupported port [$invalid_port] (#2936)" \
        "$(test -e "$tor_port_dir/launched" && echo launched || echo absent)" absent
done
rm -rf "$tor_port_dir"
unset tor_port_dir invalid_port port_output port_status
