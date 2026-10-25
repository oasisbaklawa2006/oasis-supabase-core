#!/usr/bin/env python3
"""Evidence evaluators for the whatsapp-packet-ai-consumer production release (Core #454).

Both commands are pure functions of recorded read-only data, so the release workflow's
pass/fail decisions can be regression-tested offline.

  evaluate-ticks   judge scheduler-submitted consumer ticks recorded after a release
  compare-snapshots prove a release changed no queue, dead-letter or outbound-attempt state

Exit codes: 0 pass, 1 definite failure, 3 not enough evidence yet (callers may retry).
"""
import argparse
import json
import sys
from datetime import datetime, timedelta, timezone

EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_PENDING = 3
DEFECT_CODE = "DISPATCH_CLAIM_INVALID"
HEALTHY_BODY = {"success": True, "idle": True, "processed": 0, "failed": 0, "errors": []}


def parse_ts(value):
    text = str(value).strip().replace(" ", "T")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    parsed = datetime.fromisoformat(text)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def minute_of(ts):
    return ts.replace(second=0, microsecond=0)


def consumer_result(row):
    """The consumer's result object, or None for any other recorded pg_net response."""
    try:
        body = json.loads(row.get("content") or "")
    except (TypeError, ValueError):
        return None
    if isinstance(body, dict) and all(key in body for key in HEALTHY_BODY):
        return body
    return None


def response_health(body, status):
    """Return (healthy, defect) for one consumer result."""
    errors = body.get("errors")
    defect = isinstance(errors, list) and DEFECT_CODE in errors
    healthy = status == 200 and all(body.get(key) == expected for key, expected in HEALTHY_BODY.items())
    return healthy, defect


# A minute is judged only after it has closed, with room for the tick's response to land.
CLOSE_GRACE = timedelta(seconds=20)


def evaluate_ticks(responses, since, expected_per_minute, required, now=None):
    """Judge recorded scheduler responses minute by minute.

    A minute is a healthy tick only when it holds exactly `expected_per_minute` consumer results and
    every one is healthy (extra same-shape responses cannot be attributed to a scheduler request, so
    they never vouch for a missing one). Minutes that have closed at `now` and are missing, short,
    long or unhealthy reset the run. The newest, still-open minutes are ignored while healthy so far.
    """
    since_ts = parse_ts(since)
    now_ts = parse_ts(now) if now is not None else datetime.now(timezone.utc)
    # The minute that contains `since` mixes pre- and post-release ticks; judge later minutes only.
    first_minute = minute_of(since_ts) + timedelta(minutes=1)
    buckets = {}
    defects = []
    for row in responses:
        created = parse_ts(row["created"])
        if created < since_ts:
            continue
        body = consumer_result(row)
        if body is None:
            # Unrelated or unparseable responses are not ticks; a tick that failed to
            # produce a result leaves its minute short of the expected count instead.
            continue
        healthy, defect = response_health(body, row.get("status"))
        if defect:
            defects.append({"id": row.get("id"), "created": row["created"], "status": row.get("status")})
        if minute_of(created) < first_minute:
            continue
        bucket = buckets.setdefault(minute_of(created), {"responses": 0, "healthy": 0})
        bucket["responses"] += 1
        bucket["healthy"] += 1 if healthy else 0

    last_closed = minute_of(now_ts - timedelta(minutes=1) - CLOSE_GRACE)
    run = longest = 0
    detail = []
    minute = first_minute
    while minute <= last_closed:
        info = buckets.get(minute, {"responses": 0, "healthy": 0})
        is_healthy = info["responses"] == expected_per_minute and info["healthy"] == info["responses"]
        run = run + 1 if is_healthy else 0
        longest = max(longest, run)
        detail.append({"minute": minute.isoformat(), "responses": info["responses"],
                       "healthy": info["healthy"], "tickHealthy": is_healthy})
        minute += timedelta(minutes=1)
    for minute in sorted(m for m in buckets if m > last_closed):
        info = buckets[minute]
        unhealthy_so_far = info["healthy"] != info["responses"] or info["responses"] > expected_per_minute
        if unhealthy_so_far:
            run = 0
        detail.append({"minute": minute.isoformat(), "responses": info["responses"],
                       "healthy": info["healthy"], "tickHealthy": False, "inProgress": True})

    if defects:
        verdict = "FAIL"
    elif run >= required:
        verdict = "PASS"
    else:
        verdict = "PENDING"
    return {
        "verdict": verdict,
        "requiredConsecutiveTicks": required,
        "expectedResponsesPerMinute": expected_per_minute,
        "trailingHealthyTicks": run,
        "longestHealthyRun": longest,
        "defectResponses": defects,
        "minutes": detail,
    }


# Tables a consumer release must leave untouched. Queue rows are only ever updated or deleted by processing,
# and dead letters and outbound attempts are never written by an idle tick.
GATED_TABLE_COUNTERS = {
    "whatsapp_packet_ai_dispatch_jobs": ("upd", "del"),
    "dead_letter_entries": ("ins", "upd", "del"),
    "whatsapp_case_outbound_attempts": ("ins", "upd", "del"),
}
INFORMATIONAL_TABLES = ("whatsapp_packet_ai_dispatch_jobs", "whatsapp_case_events", "whatsapp_case_department_tasks")


def compare_snapshots(before, after):
    """Compare two statistics snapshots; any gated counter that differs (or is missing) fails closed."""
    before_dml = before.get("tableDml") or {}
    after_dml = after.get("tableDml") or {}
    changed = []
    missing = []
    for table, counters in GATED_TABLE_COUNTERS.items():
        if table not in before_dml or table not in after_dml:
            missing.append(table)
            continue
        for counter in counters:
            if before_dml[table].get(counter) != after_dml[table].get(counter):
                changed.append(f"{table}.{counter}")
    informational = {}
    for table in INFORMATIONAL_TABLES:
        b, a = before_dml.get(table), after_dml.get(table)
        if b is not None and a is not None and b != a:
            informational[table] = {"before": b, "after": a}
    return {
        "verdict": "FAIL" if changed or missing else "PASS",
        "gatedCountersChanged": changed,
        "gatedTablesMissing": missing,
        "informationalDeltas": informational,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    ticks = sub.add_parser("evaluate-ticks")
    ticks.add_argument("responses_json")
    ticks.add_argument("--since", required=True)
    ticks.add_argument("--expected-per-minute", type=int, required=True)
    ticks.add_argument("--required", type=int, default=15)
    ticks.add_argument("--now", default=None, help="observation instant (default: current UTC time)")
    snap = sub.add_parser("compare-snapshots")
    snap.add_argument("before_json")
    snap.add_argument("after_json")
    args = parser.parse_args()

    if args.command == "evaluate-ticks":
        if args.expected_per_minute < 1 or args.required < 1:
            print("expected-per-minute and required must be positive", file=sys.stderr)
            return EXIT_USAGE
        with open(args.responses_json, encoding="utf-8") as handle:
            responses = json.load(handle)
        result = evaluate_ticks(responses, args.since, args.expected_per_minute, args.required, args.now)
        print(json.dumps(result, indent=2))
        verdict = result["verdict"]
        if verdict == "PASS":
            return EXIT_PASS
        if verdict == "FAIL":
            return EXIT_FAIL
        return EXIT_PENDING

    with open(args.before_json, encoding="utf-8") as handle:
        before = json.load(handle)
    with open(args.after_json, encoding="utf-8") as handle:
        after = json.load(handle)
    result = compare_snapshots(before, after)
    print(json.dumps(result, indent=2))
    return EXIT_PASS if result["verdict"] == "PASS" else EXIT_FAIL


if __name__ == "__main__":
    sys.exit(main())
