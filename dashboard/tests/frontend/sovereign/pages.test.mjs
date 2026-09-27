import assert from "node:assert/strict";
import { test } from "node:test";

import { activityRows } from "../../../mining_dashboard/web/static/sovereign/pages.mjs";

test("activityRows merges sources, rejects invalid timestamps, and sorts newest first", () => {
  const rows = activityRows({
    chart: {
      events: [{ x: 20, label: "event" }, { x: Number.NaN, label: "bad" }],
      payouts: [{ x: 30, label: "payout" }],
      raffle: [{ x: 10, label: "raffle" }],
    },
  });

  assert.deepEqual(
    rows.map(({ x, source }) => [x, source]),
    [
      [30, "Recorded payout"],
      [20, "Mining event"],
      [10, "XvB raffle"],
    ],
  );
});

test("activityRows returns at most the newest 50 records", () => {
  const rows = activityRows({
    chart: { events: Array.from({ length: 60 }, (_, x) => ({ x, label: String(x) })) },
  });

  assert.equal(rows.length, 50);
  assert.equal(rows[0].x, 59);
  assert.equal(rows.at(-1).x, 10);
});

test("activityRows tolerates a missing chart", () => {
  assert.deepEqual(activityRows({}), []);
});
