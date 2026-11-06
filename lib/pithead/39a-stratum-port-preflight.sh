validate_stratum_port_change() {
    local active_port detail STRATUM_BIND STRATUM_PORT
    validate_config_document
    validate_config_control_characters
    parse_stratum_endpoint
    active_port=$(env_get_file "$ENV_FILE" STRATUM_PORT)
    [ "$STRATUM_PORT" != "${active_port:-3333}" ] || return 0
    if ! detail=$(
        python3 - "$STRATUM_BIND" "$STRATUM_PORT" <<'PYTHON'
import errno
import socket
import sys

try:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.bind((sys.argv[1], int(sys.argv[2])))
        listener.listen(1)
except OSError as exc:
    if exc.errno == errno.EADDRINUSE:
        print("already in use on the host")
    else:
        print("could not be checked on the host: " + str(exc.strerror))
    sys.exit(1)
PYTHON
    ); then
        error "p2pool.stratum_port $STRATUM_PORT $detail. Choose an available port before applying."
    fi
}
