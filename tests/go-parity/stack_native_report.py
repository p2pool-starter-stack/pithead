#!/usr/bin/env python3
import argparse
import collections
import json
import sys
from pathlib import Path


def report(path):
    dispatches = {}
    fallbacks = {}
    results = {}
    visits = {}
    visit_results = {}
    for raw in path.read_text().splitlines():
        fields = raw.split("\t")
        if len(fields) < 5:
            raise ValueError(f"malformed native trace: {raw!r}")
        event, invocation, fragment, kind, label = fields[:5]
        key = (invocation, fragment, kind, label)
        if event == "visit" and len(fields) == 5:
            if invocation in visits:
                raise ValueError(f"duplicate fragment visit: {invocation}")
            visits[invocation] = (fragment, kind, label)
        elif event == "visit-result" and len(fields) == 6:
            if invocation in visit_results:
                raise ValueError(f"duplicate fragment result: {invocation}")
            visit_results[invocation] = (fragment, kind, label, int(fields[5]))
        elif event == "dispatch" and len(fields) == 5:
            if invocation in dispatches:
                raise ValueError(f"duplicate native dispatch: {invocation}")
            dispatches[invocation] = key
        elif event == "fallback" and len(fields) == 5:
            if invocation in fallbacks:
                raise ValueError(f"duplicate native fallback: {invocation}")
            fallbacks[invocation] = key
        elif event == "result" and len(fields) == 6:
            if invocation in results:
                raise ValueError(f"duplicate native result: {invocation}")
            results[invocation] = (key, int(fields[5]))
        else:
            raise ValueError(f"malformed native trace: {raw!r}")
    missing = sorted(set(dispatches) - set(results))
    if missing:
        raise ValueError(f"native trace has unfinished dispatches: {missing}")
    orphaned = sorted((set(results) | set(fallbacks)) - set(dispatches))
    if orphaned:
        raise ValueError(f"native trace has orphaned events: {orphaned}")
    orphaned_visits = sorted(set(visit_results) - set(visits))
    if orphaned_visits:
        raise ValueError(f"native trace has orphaned fragment results: {orphaned_visits}")
    invalid_visits = sorted(
        invocation
        for invocation, (_, kind, mode) in visits.items()
        if kind != "fragment" or mode not in {"direct", "source"}
    )
    if invalid_visits:
        raise ValueError(f"native trace has invalid fragment visits: {invalid_visits}")
    mismatched_visits = sorted(
        invocation
        for invocation, (fragment, kind, label, _) in visit_results.items()
        if visits[invocation] != (fragment, kind, label)
    )
    if mismatched_visits:
        raise ValueError(f"native trace has mismatched fragment results: {mismatched_visits}")
    mismatched_results = sorted(
        invocation for invocation, (key, _) in results.items() if dispatches[invocation] != key
    )
    if mismatched_results:
        raise ValueError(f"native trace has mismatched native results: {mismatched_results}")
    mismatched_fallbacks = sorted(
        invocation for invocation, key in fallbacks.items() if dispatches[invocation] != key
    )
    if mismatched_fallbacks:
        raise ValueError(f"native trace has mismatched native fallbacks: {mismatched_fallbacks}")
    invalid = sorted(invocation for invocation in fallbacks if dispatches[invocation][2] != "cli")
    if invalid:
        raise ValueError(f"helpers marked as reference fallbacks: {invalid}")
    counts = collections.defaultdict(lambda: collections.Counter())
    helpers = collections.defaultdict(collections.Counter)
    completeness = collections.Counter()
    if not visits:
        completeness["no_fragment_visits"] = 1
    for invocation, (fragment, _, mode) in visits.items():
        row = counts[fragment]
        row["visits"] += 1
        if invocation in visit_results:
            row[f"source_status_{visit_results[invocation][3]}"] += 1
        elif mode == "source":
            row["unfinished_sources"] += 1
            completeness["unfinished_sources"] += 1
        else:
            row["unobserved_direct_statuses"] += 1
            completeness["unobserved_direct_statuses"] += 1
    for invocation, (_, fragment, kind, label) in dispatches.items():
        rc = results[invocation][1]
        row = counts[fragment]
        row["dispatches"] += 1
        if invocation in fallbacks:
            row["reference_fallbacks"] += 1
        elif kind == "helper" and rc == 125:
            row["compatibility_fallbacks"] += 1
            helpers[label]["compatibility_fallbacks"] += 1
        elif kind == "helper" and rc == 1:
            row["native_rejections"] += 1
            helpers[label]["native_rejections"] += 1
        elif rc == 0:
            row["native_successes"] += 1
            if kind == "helper":
                helpers[label]["native_successes"] += 1
        else:
            row["native_errors"] += 1
            if kind == "helper":
                helpers[label]["native_errors"] += 1
    return {
        "fragments": {key: dict(sorted(value.items())) for key, value in sorted(counts.items())},
        "helpers": {key: dict(sorted(value.items())) for key, value in sorted(helpers.items())},
        "completeness": dict(sorted(completeness.items())),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("trace", type=Path)
    parser.add_argument("--require-native", action="append", default=[])
    parser.add_argument("--assert-complete", action="store_true")
    parser.add_argument("--suite-exit-status", type=int)
    arguments = parser.parse_args()
    try:
        result = report(arguments.trace)
    except (OSError, ValueError) as error:
        print(error, file=sys.stderr)
        return 2
    print(json.dumps(result, indent=2, sort_keys=True))
    if arguments.require_native:
        failed = [
            helper
            for helper in arguments.require_native
            if result["helpers"].get(helper, {}).get("native_successes", 0) == 0
        ]
        if failed:
            print("required helpers without native success: " + ", ".join(failed))
            return 1
    if arguments.assert_complete:
        incomplete = result["completeness"]
        if incomplete.get("no_fragment_visits", 0):
            print("trace has no fragment visits")
            return 1
        if incomplete.get("unfinished_sources", 0):
            print("trace has unfinished sourced fragments")
            return 1
        if incomplete.get("unobserved_direct_statuses", 0) and arguments.suite_exit_status is None:
            print("direct fragment status requires --suite-exit-status")
            return 1
        if arguments.suite_exit_status not in (None, 0):
            print(f"outer suite failed with status {arguments.suite_exit_status}")
            return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
