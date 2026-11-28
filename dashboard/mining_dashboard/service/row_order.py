from mining_dashboard.helper.time_rows import TimeOrdered, rows_ordered


class RowOrder:
    def __init__(self):
        self._seen = {}

    def view(self, name, field, rows):
        n = len(rows)
        seen = self._seen.get(name)
        if not (
            seen is not None
            and seen[0] is rows
            and seen[1] == n
            and (n == 0 or (seen[2] is rows[0] and seen[3] is rows[-1]))
        ):
            seen = (
                rows,
                n,
                rows[0] if n else None,
                rows[-1] if n else None,
                rows_ordered(rows, field),
            )
            self._seen[name] = seen
        return TimeOrdered(rows, field) if seen[4] else list(rows)
