bundle_support_cap_py() {
    cat <<'PY'
import collections, json, sys

CAP_LINES_HEAD_SHARE = 4


def cap_lines(lines, cap):
    head_budget = cap // CAP_LINES_HEAD_SHARE
    tail_budget = cap
    head, head_bytes, in_tail = [], 0, False
    tail, tail_bytes = collections.deque(), 0
    dropped_lines = dropped_bytes = total_lines = total_bytes = 0
    for line in lines:
        total_lines += 1
        total_bytes += len(line)
        if not in_tail and head_bytes + len(line) <= head_budget:
            head.append(line)
            head_bytes += len(line)
            continue
        if not in_tail:
            in_tail = True
            tail_budget = cap - head_bytes
        tail.append(line)
        tail_bytes += len(line)
        while tail_bytes > tail_budget and tail:
            gone = tail.popleft()
            tail_bytes -= len(gone)
            dropped_lines += 1
            dropped_bytes += len(gone)
    out = list(head)
    if dropped_lines:
        out.append(
            (
                "[pithead support bundle: %d lines (%d bytes) omitted here to keep this file within its %d byte cap; the oldest and newest lines of the window are kept]\n"
                % (dropped_lines, dropped_bytes, cap)
            ).encode()
        )
    out.extend(tail)
    return out, total_lines, total_bytes, dropped_lines, dropped_bytes


def state_for(lines, installed, short):
    if lines == 0:
        return "empty" if installed else "missing"
    return "journal_short" if short else "ok"


def stream_cap(dest, cap, meta, installed, short, since, until):
    out, total_lines, total_bytes, dropped_lines, dropped_bytes = cap_lines(sys.stdin.buffer, cap)
    with open(dest, "wb") as fh:
        fh.writelines(out)
    with open(meta, "w") as fh:
        json.dump(
            {
                "state": state_for(total_lines, installed, short),
                "lines": total_lines,
                "window": {"since": since, "until": until},
                "truncated": dropped_lines > 0,
                "dropped_lines": dropped_lines,
                "dropped_bytes": dropped_bytes,
            },
            fh,
        )


if __name__ == "__main__":
    dest, cap, meta, installed, short, since, until = sys.argv[1:8]
    stream_cap(dest, int(cap), meta, installed == "1", short == "1", since, until)
PY
}

bundle_support_pack_py() {
    cat <<'PY'
import json, os, sys, zipfile

sys.path.insert(0, os.environ["PITHEAD_PACK_CAPDIR"])
import cap

bundle, metadir, info_path, steps_path, zip_out, total_cap = sys.argv[1:7]
total_cap = int(total_cap)
FLOOR = 64 * 1024


def read_meta(rel):
    path = os.path.join(metadir, rel.replace("/", "__") + ".json")
    try:
        with open(path) as fh:
            return path, json.load(fh)
    except (OSError, ValueError):
        return path, None


def files():
    found = []
    for root, _dirs, names in os.walk(bundle):
        for name in names:
            full = os.path.join(root, name)
            found.append((os.path.relpath(full, bundle), full))
    return sorted(found)


def total_size():
    return sum(os.path.getsize(full) for _rel, full in files())


info = json.load(open(info_path))
failures = []
if os.path.exists(steps_path):
    for row in open(steps_path).read().splitlines():
        step, status, reason, elapsed = (row.split("\t") + ["", "", "0"])[:4]
        failures.append({"step": step, "status": status, "reason": reason, "elapsed_seconds": int(elapsed or 0)})

stuck = set()
while total_size() > total_cap:
    candidates = [
        (os.path.getsize(full), rel, full)
        for rel, full in files()
        if rel not in stuck and read_meta(rel)[1] is not None and os.path.getsize(full) > FLOOR
    ]
    if not candidates:
        failures.append({"step": "total-cap", "status": "failed", "reason": "bundle is over the total cap and no file can shrink further"})
        break
    size, rel, full = max(candidates)
    mpath, meta = read_meta(rel)
    target = max(FLOOR, size // 2)
    if target == FLOOR:
        stuck.add(rel)
    with open(full, "rb") as fh:
        out, _tl, _tb, dl, db = cap.cap_lines(fh, target)
    with open(full, "wb") as fh:
        fh.writelines(out)
    meta["truncated"] = True
    meta["dropped_lines"] += dl
    meta["dropped_bytes"] += db
    with open(mpath, "w") as fh:
        json.dump(meta, fh)

entries = []
for rel, full in files():
    _p, meta = read_meta(rel)
    entry = {"path": rel, "bytes": os.path.getsize(full)}
    if meta is None:
        entry.update(state="ok", window=None, truncated=False, dropped_lines=0, dropped_bytes=0)
    else:
        entry.update(
            state=meta["state"],
            window=meta["window"],
            truncated=meta["truncated"],
            dropped_lines=meta["dropped_lines"],
            dropped_bytes=meta["dropped_bytes"],
            lines=meta["lines"],
        )
    entries.append(entry)

manifest = dict(info)
manifest["files"] = entries
manifest["failures"] = failures
with open(os.path.join(bundle, "manifest.json"), "w") as fh:
    json.dump(manifest, fh, indent=2, sort_keys=True)
    fh.write("\n")

fd = os.open(zip_out, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(fd, "wb") as raw, zipfile.ZipFile(raw, "w", zipfile.ZIP_DEFLATED) as zf:
    for rel, full in files():
        zf.write(full, "bundle/" + rel)
PY
}
