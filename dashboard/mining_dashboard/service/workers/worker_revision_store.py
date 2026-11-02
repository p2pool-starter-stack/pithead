def prepare(cursor, worker, revision, last_change_id, resolve):
    cursor.execute(
        "SELECT revision, last_change_id, drift_from FROM worker_config_revision WHERE worker = ?",
        (worker,),
    )
    row = cursor.fetchone()
    return row, resolve(row, revision, last_change_id)


def write(conn, worker, revision, last_change_id, now, drift_from):
    conn.execute(
        "INSERT OR REPLACE INTO worker_config_revision "
        "(worker, revision, last_change_id, ts, drift_from) VALUES (?, ?, ?, ?, ?)",
        (worker, revision, last_change_id, now, drift_from),
    )


def prune(conn, cutoff):
    conn.execute("DELETE FROM worker_config_revision WHERE ts < ?", (cutoff,))


def drift(cursor, worker, revision):
    del revision
    cursor.execute(
        "SELECT revision, drift_from FROM worker_config_revision WHERE worker = ?",
        (worker,),
    )
    return cursor.fetchone()


def visible(row, revision):
    return not (row is None or not row["drift_from"] or row["revision"] != revision)
