import bisect
from operator import eq, itemgetter, le


class TimeOrdered(list):
    __slots__ = ("field",)

    def __init__(self, rows=(), field=None):
        super().__init__(rows)
        self.field = field


def _demoting(name):
    method = getattr(list, name)

    def mutate(self, *args, **kwargs):
        self.field = None
        return method(self, *args, **kwargs)

    return mutate


for _name in (
    "__setitem__",
    "__delitem__",
    "__iadd__",
    "__imul__",
    "append",
    "extend",
    "insert",
    "pop",
    "remove",
    "clear",
    "sort",
    "reverse",
):
    setattr(TimeOrdered, _name, _demoting(_name))


def rows_ordered(rows, field):
    try:
        values = list(map(itemgetter(field), rows))
        ordered = all(map(le, values, values[1:])) and (
            len(values) != 1 or eq(values[0], values[0])
        )
    except (KeyError, TypeError):
        ordered = False
    return ordered


def window_rows(rows, field, lo, hi=None):
    if (
        isinstance(rows, TimeOrdered)
        and rows.field == field
        and lo == lo
        and (hi is None or hi == hi)
    ):
        key = itemgetter(field)
        start = bisect.bisect_left(rows, lo, key=key)
        return rows[start:] if hi is None else rows[start : bisect.bisect_right(rows, hi, key=key)]
    return rows


def numeric_column(rows, col, kinds=frozenset({int, float})):
    try:
        values = list(map(itemgetter(col), rows))
    except (KeyError, TypeError, IndexError):
        values = []
    seen = set(map(type, values))
    return values if len(seen) == 1 and seen <= kinds else None
