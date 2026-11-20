bundle_support_snap_py() {
    cat <<'PY'
import gzip, json, os, re, sqlite3, stat, subprocess, sys, time


def unavailable(service, reason, **extra):
    doc = {"service": service, "reachable": False, "reason": reason}
    doc.update(extra)
    print(json.dumps(doc, indent=2, sort_keys=True))
    sys.stderr.write(reason + "\n")
    sys.exit(3)


def pb_fields(data):
    out, pos = {}, 0
    while pos < len(data):
        key, pos = pb_varint(data, pos)
        field, wire = key >> 3, key & 7
        if wire == 0:
            val, pos = pb_varint(data, pos)
        elif wire == 2:
            size, pos = pb_varint(data, pos)
            val, pos = data[pos : pos + size], pos + size
        elif wire == 1:
            val, pos = data[pos : pos + 8], pos + 8
        elif wire == 5:
            val, pos = data[pos : pos + 4], pos + 4
        else:
            raise ValueError("unsupported protobuf wire type")
        out.setdefault(field, val)
    return out


def pb_varint(data, pos):
    shift = value = 0
    while pos < len(data):
        byte = data[pos]
        pos += 1
        value |= (byte & 0x7F) << shift
        if not byte & 0x80:
            return value, pos
        shift += 7
    raise ValueError("truncated protobuf")


def grpc(addr, method):
    r = subprocess.run(
        ["curl", "-fsS", "--http2-prior-knowledge", "--max-time", "5", "--max-filesize", "65536", "-D", "/dev/stderr",
         "-H", "content-type: application/grpc", "-H", "te: trailers", "--data-binary", "@-",
         "http://%s/tari.rpc.BaseNode/%s" % (addr, method)],
        input=b"\x00" * 5, capture_output=True, timeout=8,
    )
    if r.returncode:
        raise RuntimeError("curl exit %d: %s" % (r.returncode, r.stderr.decode(errors="replace").strip().splitlines()[-1:] or [""])[0])
    if not re.search(rb"grpc-status:\s*0\b", r.stderr, re.I):
        raise RuntimeError("gRPC call did not succeed")
    frame = r.stdout
    if len(frame) < 5 or frame[0] or int.from_bytes(frame[1:5], "big") != len(frame) - 5:
        raise RuntimeError("invalid gRPC frame")
    return pb_fields(frame[5:])


def tari(addr):
    try:
        tip = grpc(addr, "GetTipInfo")
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        unavailable("tari", "tari base node did not answer: %s" % exc)
    meta = pb_fields(tip.get(1, b""))
    doc = {"service": "tari", "reachable": True, "height": meta.get(1), "synced": bool(tip.get(2, 0)),
           "base_node_state": tip.get(3, 0), "peers": None}
    try:
        doc["peers"] = grpc(addr, "GetNetworkStatus").get(3, 0)
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        doc["peers_error"] = str(exc)
    print(json.dumps(doc, indent=2, sort_keys=True))


def monerod(url):
    cmd = ["curl", "-fsS", "--max-time", "8", "--max-filesize", "1048576"]
    stdin = None
    user = os.environ.get("PITHEAD_SNAP_USER", "")
    if user:
        cmd += ["--digest", "--config", "-"]
        stdin = "user = %s\n" % json.dumps(user + ":" + os.environ.get("PITHEAD_SNAP_PASS", ""))
    cmd.append(url.rstrip("/") + "/get_info")
    try:
        r = subprocess.run(cmd, input=stdin, capture_output=True, text=True, timeout=12)
        if r.returncode:
            raise RuntimeError("curl exit %d: %s" % (r.returncode, (r.stderr.strip().splitlines() or [""])[-1]))
        info = json.loads(r.stdout)
    except (RuntimeError, ValueError, OSError, subprocess.SubprocessError) as exc:
        unavailable("monerod", "monerod RPC did not answer: %s" % exc)
    doc = {"service": "monerod", "reachable": True}
    for key in ("status", "height", "target_height", "synchronized", "busy_syncing", "offline", "nettype",
                "version", "outgoing_connections_count", "incoming_connections_count",
                "white_peerlist_size", "grey_peerlist_size", "database_size", "restricted"):
        if key in info:
            doc[key] = info[key]
    doc["peers"] = {"outgoing": info.get("outgoing_connections_count"), "incoming": info.get("incoming_connections_count")}
    doc["note"] = "a restricted RPC reports 0 for the connection counts"
    print(json.dumps(doc, indent=2, sort_keys=True))


def p2pool(stats):
    now = time.time()
    doc = {"service": "p2pool", "files": {}}
    data = {}
    for name in ("local/stratum", "local/p2p", "pool/stats", "network/stats"):
        path = os.path.join(stats, name)
        try:
            age = int(now - os.stat(path).st_mtime)
            with open(path) as fh:
                data[name] = json.load(fh)
            doc["files"][name] = {"age_seconds": age}
        except (OSError, ValueError) as exc:
            doc["files"][name] = {"error": type(exc).__name__}
    if not data:
        unavailable("p2pool", "no p2pool data-api file was readable under the stats directory", files=doc["files"])
    pool = (data.get("pool/stats") or {}).get("pool_statistics") or {}
    ages = [f["age_seconds"] for f in doc["files"].values() if "age_seconds" in f]
    doc.update(
        reachable=True,
        monero_height=(data.get("network/stats") or {}).get("height"),
        sidechain_height=pool.get("sidechainHeight"),
        peers=(data.get("local/p2p") or {}).get("connections"),
        stratum_connections=(data.get("local/stratum") or {}).get("connections"),
        synced=bool(ages) and max(ages) < 600 and bool(pool.get("sidechainHeight")),
        note="synced is derived: every readable data-api file is under ten minutes old and the sidechain height is known",
    )
    print(json.dumps(doc, indent=2, sort_keys=True))


def caddy(directory, since, until):
    try:
        names = sorted(n for n in os.listdir(directory) if re.match(r"^access.*\.log(\.gz)?$", n))
    except OSError as exc:
        sys.stderr.write("the Caddy log directory is not readable: %s\n" % type(exc).__name__)
        sys.exit(3)
    safe = {"user-agent", "content-type", "content-length", "accept", "accept-language", "accept-encoding", "host",
            "x-forwarded-for", "x-forwarded-proto", "server", "cache-control", "connection"}
    for name in names:
        path = os.path.join(directory, name)
        if not os.path.isfile(path) or os.path.islink(path) or os.path.getmtime(path) < since:
            continue
        opener = gzip.open if name.endswith(".gz") else open
        with opener(path, "rt", errors="replace") as fh:
            for line in fh:
                try:
                    entry = json.loads(line)
                    ts = float(entry["ts"])
                except (ValueError, KeyError, TypeError):
                    continue
                if not since <= ts <= until + 1:
                    continue
                request = entry.get("request")
                for headers in (request.get("headers") if isinstance(request, dict) else None, entry.get("resp_headers")):
                    if isinstance(headers, dict):
                        for header in headers:
                            if header.lower() not in safe:
                                headers[header] = ["[redacted]"]
                if isinstance(request, dict):
                    for field in ("uri", "url"):
                        if isinstance(request.get(field), str):
                            path, mark, _query = request[field].partition("?")
                            path = re.sub(r"[A-Za-z0-9_.~%-]{20,}", "[redacted]", path)
                            request[field] = path + (mark + "[redacted]" if mark else "")
                print(json.dumps(entry, sort_keys=True))


HISTORY_TABLES = (
    ("history", "timestamp"), ("events", "ts"), ("share_stats", "ts"), ("blocks", "ts"), ("shares", "ts"),
    ("xvb_history", "ts"), ("network_history", "ts"), ("disk_growth", "ts"), ("worker_history", "ts"), ("raffle_wins", "ts"),
    ("ping_failures", "ts"), ("audit_events", "ts"),
)


def iso(epoch):
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(epoch))


def history(db, since, until):
    try:
        conn = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=5)
        conn.execute("PRAGMA busy_timeout=5000")
        conn.row_factory = sqlite3.Row
    except sqlite3.Error as exc:
        sys.stderr.write("dashboard database could not be opened: %s\n" % exc)
        sys.exit(3)
    failed = 0
    for table, col in HISTORY_TABLES:
        lo, hi = (iso(since), iso(until)) if table == "audit_events" else (since, until)
        try:
            cur = conn.execute("SELECT * FROM %s WHERE %s >= ? AND %s <= ? ORDER BY %s" % (table, col, col, col), (lo, hi))
            for row in cur:
                print(json.dumps({"table": table, "row": dict(row)}, sort_keys=True, default=str))
        except sqlite3.Error as exc:
            failed += 1
            print(json.dumps({"table": table, "error": str(exc)}))
    if failed == len(HISTORY_TABLES):
        sys.stderr.write("no dashboard history table could be read\n")
        sys.exit(3)


def markers(root):
    skip = re.compile(r"key|secret|token|cookie|pass|seed|mnemonic|wallet|cred|auth|url|login|env|host|rpc|user|addr|onion|private|\.pem$", re.I)
    count = 0
    for base, dirs, names in os.walk(root):
        depth = base[len(root):].count(os.sep)
        dirs[:] = sorted(d for d in dirs if d != "support-bundles") if depth < 1 else []
        for name in sorted(dirs) + sorted(names):
            path = os.path.join(base, name)
            try:
                st = os.lstat(path)
            except OSError:
                continue
            count += 1
            if count > 500:
                print("[listing stopped at 500 entries]")
                return
            kind = "d" if stat.S_ISDIR(st.st_mode) else "l" if stat.S_ISLNK(st.st_mode) else "f"
            print("%s %d %s %s" % (kind, st.st_size, iso(st.st_mtime), os.path.relpath(path, root)))
            if kind == "f" and st.st_size <= 256 and not skip.search(name):
                try:
                    with open(path, errors="replace") as fh:
                        body = fh.read(256).strip()
                except OSError:
                    continue
                if body and not re.search(r"[A-Za-z0-9+/_-]{24,}|://", body):
                    print("    content: %s" % body.replace("\n", " | "))


if __name__ == "__main__":
    mode, args = sys.argv[1], sys.argv[2:]
    if mode in ("caddy", "history"):
        {"caddy": caddy, "history": history}[mode](args[0], float(args[1]), float(args[2]))
    else:
        {"tari": tari, "monerod": monerod, "p2pool": p2pool, "markers": markers}[mode](*args)
PY
}

bundle_support_mark_unavailable() {
    printf '{"state":"unavailable","lines":1,"window":{"since":"%s","until":"%s"},"truncated":false,"dropped_lines":0,"dropped_bytes":0}' \
        "$_BS_SINCE" "$_BS_UNTIL" >"$1/meta/${2//\//__}.json"
}

bundle_support_snap() {
    local tmp="$1" rel="$2" f
    shift 2
    f="$tmp/bundle/$rel"
    mkdir -p "$(dirname "$f")"
    if ! command -v "$1" >/dev/null 2>&1; then
        bundle_support_step_fail "$tmp" "$rel" not_installed "$1 is not installed" 0
        printf 'unavailable: %s is not installed\n' "$1" >"$f"
        bundle_support_mark_unavailable "$tmp" "$rel"
        return 0
    fi
    BUNDLE_STEP_LIMIT="${BUNDLE_STEP_LIMIT:-${PITHEAD_SUPPORT_SNAP_TIMEOUT:-20}}" \
        bundle_support_capture "$tmp" "$rel" "$_BS_CAP" 1 0 "$_BS_SINCE" "$_BS_UNTIL" "$@" || true
    if [ ! -s "$f" ]; then
        printf 'unavailable: this step produced no output; see failures in manifest.json\n' >"$f"
        bundle_support_mark_unavailable "$tmp" "$rel"
    fi
}

bundle_support_snap_skip() {
    local tmp="$1" rel="$2" why="$3"
    mkdir -p "$tmp/bundle/$(dirname "$rel")"
    printf 'unavailable: %s\n' "$why" >"$tmp/bundle/$rel"
    bundle_support_mark_unavailable "$tmp" "$rel"
    bundle_support_step_fail "$tmp" "$rel" skipped "$why" 0
}

bundle_support_snapshots() {
    local tmp="$1" engine profiles rpc_url tari_addr p2dir tordir cdir db sdir f rel n
    local nfmt='{{.Names}} state={{.State}} status={{.Status}} exit_code={{.ExitCode}} image={{.Image}} image_id={{.ImageID}}'
    local py="$tmp/snap.py"
    engine=$(container_engine)
    [ "$engine" = podman ] || nfmt='{{.Names}} state={{.State}} status={{.Status}} image={{.Image}}'
    profiles=$(env_get COMPOSE_PROFILES 2>/dev/null || true)
    rpc_url=$(env_get MONERO_RPC_URL 2>/dev/null || true)
    tari_addr=$(env_get TARI_GRPC_ADDRESS 2>/dev/null || true)
    p2dir=$(env_get P2POOL_DATA_DIR 2>/dev/null || true)
    tordir=$(env_get TOR_DATA_DIR 2>/dev/null || true)
    cdir=$(env_get CADDY_LOG_DIR 2>/dev/null || true)
    : "${rpc_url:=http://127.0.0.1:18081}" "${tari_addr:=127.0.0.1:18142}" "${p2dir:=$PWD/data/p2pool}" "${tordir:=$PWD/data/tor}" "${cdir:=$PWD/data/caddy-logs}"

    BUNDLE_STEP_LIMIT="${PITHEAD_SUPPORT_DOCTOR_TIMEOUT:-90}" BUNDLE_OK_RC="1" \
        bundle_support_snap "$tmp" doctor.json "${PITHEAD_SELF:-$0}" doctor --json

    if [ -n "$profiles" ] && [[ ",$profiles," != *,local_node,* ]]; then
        bundle_support_snap_skip "$tmp" status/monerod.json "the Monero node is remote; the host does not query it"
    else
        PITHEAD_SNAP_USER=$(env_get MONERO_NODE_USERNAME 2>/dev/null || true) \
        PITHEAD_SNAP_PASS=$(env_get MONERO_NODE_PASSWORD 2>/dev/null || true) \
            bundle_support_snap "$tmp" status/monerod.json python3 -I "$py" monerod "$rpc_url"
    fi
    if [ -n "$profiles" ] && [[ ",$profiles," != *,local_tari,* ]]; then
        bundle_support_snap_skip "$tmp" status/tari.json "the Tari node is remote or off; the host does not query it"
    else
        bundle_support_snap "$tmp" status/tari.json python3 -I "$py" tari "$tari_addr"
    fi
    bundle_support_snap "$tmp" status/p2pool.json python3 -I "$py" p2pool "$p2dir/stats"
    export -f tor_diagnostics_snapshot
    bundle_support_snap "$tmp" tor/diagnostics.json bash -c tor_diagnostics_snapshot
    bundle_support_snap "$tmp" tor/state-guards.txt awk '/^(TorVersion|LastWritten|Guard) / { gsub(/bridge_addr=[^ ]+/, "bridge_addr=[redacted]"); gsub(/rsa_id=[^ ]+/, "rsa_id=[redacted]"); gsub(/nickname=[^ ]+/, "nickname=[redacted]"); print }' "$tordir/state"

    bundle_support_snap "$tmp" network/networkctl.txt networkctl status --no-pager
    bundle_support_snap "$tmp" network/ip-addr.txt ip addr
    bundle_support_snap "$tmp" network/ip-route.txt ip route
    bundle_support_snap "$tmp" network/resolvectl.txt resolvectl status --no-pager
    BUNDLE_ADDR_REDACT=1 bundle_support_snap "$tmp" network/nft-ruleset.txt nft list ruleset
    bundle_support_snap "$tmp" time/timedatectl.txt timedatectl status
    bundle_support_snap "$tmp" time/sync-units.txt systemctl show systemd-timesyncd.service chronyd.service \
        -p Id -p LoadState -p ActiveState -p SubState -p Result -p ExecMainStatus -p ActiveEnterTimestamp

    bundle_support_snap "$tmp" containers/ps-a.txt "$engine" ps -a --no-trunc --format "$nfmt"
    bundle_support_snap "$tmp" containers/images.txt "$engine" images --digests --no-trunc
    bundle_support_snap "$tmp" rauc.txt rauc status
    bundle_support_snap "$tmp" rauc-detailed.txt rauc status --detailed
    bundle_support_snap "$tmp" boot-slot.txt cat /proc/cmdline
    bundle_support_snap "$tmp" coredumps.txt coredumpctl list --no-pager

    bundle_support_snap "$tmp" caddy/access.log python3 -I "$py" caddy "$cdir" "$_BS_SINCE_EPOCH" "$_BS_UNTIL_EPOCH"

    sdir="${PITHEAD_SUPPORT_DIR:-/data/pithead/support}"
    if [ -d "$sdir" ]; then
        n=0
        while IFS= read -r -d '' f; do
            n=$((n + 1))
            if [ "$n" -gt 2000 ]; then
                bundle_support_step_fail "$tmp" support-dir failed "more than 2000 files; the rest are not included" 0
                break
            fi
            rel="support-dir/$(printf '%s' "${f#"$sdir"/}" | tr -c 'A-Za-z0-9._/-' '_')"
            [ -e "$tmp/bundle/$rel" ] && rel="$rel.$n"
            bundle_support_snap "$tmp" "$rel" cat -- "$f"
        done < <(find "$sdir" -type f -print0 2>/dev/null | sort -z)
    else
        bundle_support_snap_skip "$tmp" support-dir/README.txt "no $sdir directory on this box"
    fi
    bundle_support_snap "$tmp" state-markers.txt python3 -I "$py" markers "${PITHEAD_STATE_ROOT:-/data/pithead}"

    db="${DASHBOARD_DATA_DIR:-}/mining_data.db"
    [ -f "$db" ] || db="$(env_get DASHBOARD_DATA_DIR 2>/dev/null || true)/mining_data.db"
    [ -f "$db" ] || db="/data/pithead/dashboard/mining_data.db"
    [ -f "$db" ] || db="/data/mining_data.db"
    if [ -f "$db" ]; then
        bundle_support_snap "$tmp" dashboard-history.jsonl python3 -I "$py" history "$db" "$_BS_SINCE_EPOCH" "$_BS_UNTIL_EPOCH"
    else
        bundle_support_snap_skip "$tmp" dashboard-history.jsonl "no dashboard database was found on this box"
    fi
}
