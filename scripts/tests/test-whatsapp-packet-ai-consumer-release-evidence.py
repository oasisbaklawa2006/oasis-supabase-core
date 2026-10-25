#!/usr/bin/env python3
"""Regression tests for the consumer release evidence evaluators (Core #454)."""
import importlib.util
import json
import os
import subprocess
import tempfile
import unittest
from datetime import datetime, timedelta, timezone

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SCRIPT = os.path.join(ROOT, "scripts", "whatsapp-packet-ai-consumer-release-evidence.py")
OBSERVE = os.path.join(ROOT, "scripts", "observe-whatsapp-packet-ai-consumer-ticks.sh")
spec = importlib.util.spec_from_file_location("evidence", SCRIPT)
evidence = importlib.util.module_from_spec(spec)
spec.loader.exec_module(evidence)

SINCE = datetime(2026, 10, 26, 9, 0, 30, tzinfo=timezone.utc)
IDLE = json.dumps({"success": True, "idle": True, "processed": 0, "failed": 0, "errors": []})
CLAIM_INVALID = json.dumps({
    "success": False, "idle": False, "processed": 0, "failed": 3,
    "errors": ["DISPATCH_CLAIM_INVALID"] * 3,
})
_next_id = [1]


def row(minute_offset, status=200, content=IDLE, second=1):
    base = SINCE.replace(second=0) + timedelta(minutes=minute_offset, seconds=second)
    _next_id[0] += 1
    return {"id": _next_id[0], "status": status, "created": base.isoformat(), "content": content}


def healthy_minutes(first, last, per_minute=2):
    return [row(m, second=s * 10 + 1) for m in range(first, last + 1) for s in range(per_minute)]


def run(responses, required=15, per_minute=2):
    return evidence.evaluate_ticks(responses, SINCE.isoformat(), per_minute, required)


class EvaluateTicks(unittest.TestCase):
    def test_fifteen_consecutive_healthy_minutes_pass(self):
        result = run(healthy_minutes(1, 15))
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["trailingHealthyTicks"], 15)

    def test_fourteen_minutes_is_not_enough(self):
        result = run(healthy_minutes(1, 14))
        self.assertEqual(result["verdict"], "PENDING")
        self.assertEqual(result["trailingHealthyTicks"], 14)

    def test_the_original_defect_pattern_fails(self):
        responses = []
        for m in range(1, 17):
            responses.append(row(m, 502, CLAIM_INVALID, second=1))
            responses.append(row(m, 200, IDLE, second=2))
        result = run(responses)
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(len(result["defectResponses"]), 16)

    def test_defect_before_the_release_instant_is_ignored(self):
        responses = [row(-3, 502, CLAIM_INVALID)] + healthy_minutes(1, 15)
        self.assertEqual(run(responses)["verdict"], "PASS")

    def test_partial_first_minute_is_not_counted(self):
        # The minute containing `since` mixes old and new code; only later minutes count.
        responses = healthy_minutes(0, 14)
        result = run(responses)
        self.assertEqual(result["trailingHealthyTicks"], 14)
        self.assertEqual(result["verdict"], "PENDING")

    def test_post_release_ticks_in_the_mixed_first_minute_are_not_judged(self):
        mixed = [row(0, 500, "upstream hiccup", second=45), row(0, 200, IDLE, second=50)]
        result = run(mixed + healthy_minutes(1, 15))
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["minutes"][0]["minute"][:16], "2026-10-26T09:01")

    def test_the_newest_in_progress_minute_does_not_reset_a_proven_run(self):
        result = run(healthy_minutes(1, 15) + [row(16)])
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(result["trailingHealthyTicks"], 15)

    def test_an_in_progress_minute_after_a_gap_still_resets_the_run(self):
        result = run(healthy_minutes(1, 15) + [row(17)])
        self.assertEqual(result["trailingHealthyTicks"], 0)

    def test_an_unhealthy_newest_minute_is_not_skipped(self):
        result = run(healthy_minutes(1, 15) + [row(16, 200, json.dumps({"success": False, "idle": True, "processed": 0, "failed": 0, "errors": []}))])
        self.assertEqual(result["trailingHealthyTicks"], 0)

    def test_a_missing_minute_resets_the_run(self):
        responses = healthy_minutes(1, 7) + healthy_minutes(9, 20)
        result = run(responses)
        self.assertEqual(result["trailingHealthyTicks"], 12)
        self.assertEqual(result["longestHealthyRun"], 12)
        self.assertEqual(result["verdict"], "PENDING")

    def test_a_minute_missing_one_expected_response_is_unhealthy(self):
        responses = healthy_minutes(1, 7) + [row(8)] + healthy_minutes(9, 20)
        self.assertEqual(run(responses)["verdict"], "PENDING")

    def test_non_idle_tick_resets_but_is_not_the_original_defect(self):
        busy = json.dumps({"success": True, "idle": False, "processed": 1, "failed": 0, "errors": []})
        responses = healthy_minutes(1, 4) + [row(5, 200, busy), row(5, 200, IDLE)] + healthy_minutes(6, 14)
        result = run(responses)
        self.assertEqual(result["verdict"], "PENDING")
        self.assertEqual(result["trailingHealthyTicks"], 9)
        self.assertEqual(result["defectResponses"], [])

    def test_http_200_with_success_false_is_unhealthy(self):
        bad = json.dumps({"success": False, "idle": True, "processed": 0, "failed": 0, "errors": []})
        responses = healthy_minutes(1, 3) + [row(4, 200, bad), row(4)] + healthy_minutes(5, 20)
        self.assertEqual(run(responses)["longestHealthyRun"], 16)
        self.assertEqual(run(healthy_minutes(1, 3) + [row(4, 200, bad), row(4)])["trailingHealthyTicks"], 0)

    def test_malformed_or_missing_content_is_unhealthy(self):
        for content in (None, "", "not json", "[]"):
            result = run([row(1, 200, content), row(1)], required=1)
            self.assertEqual(result["verdict"], "PENDING", content)

    def test_unrelated_http_responses_are_not_ticks(self):
        noise = [row(m, 200, json.dumps({"ok": True}), second=30) for m in range(1, 16)]
        noise += [row(m, 504, "<html>gateway</html>", second=35) for m in range(1, 16)]
        self.assertEqual(run(healthy_minutes(1, 15) + noise)["verdict"], "PASS")

    def test_a_tick_without_a_result_leaves_its_minute_short(self):
        responses = healthy_minutes(1, 7) + [row(8), row(8, 504, "<html>gateway timeout</html>")] + healthy_minutes(9, 20)
        self.assertEqual(run(responses)["longestHealthyRun"], 12)

    def test_extra_responses_in_a_minute_must_all_be_healthy(self):
        responses = healthy_minutes(1, 15) + [row(7, 502, CLAIM_INVALID, second=40)]
        self.assertEqual(run(responses)["verdict"], "FAIL")


class CompareSnapshots(unittest.TestCase):
    base = {
        "dispatchJobStates": {"COMPLETED": 219, "DEAD_LETTERED": 1},
        "dispatchJobsMaxUpdatedAt": "2026-10-24T10:00:00+00:00",
        "dispatchJobsMaxAttemptCount": 4,
        "deadLetterEntries": 7,
        "caseOutboundAttempts": 0,
        "caseEvents": 100,
        "departmentTasks": 134,
        "activeConsumerCronJobs": 2,
    }

    def after(self, **changes):
        merged = dict(self.base)
        merged.update(changes)
        return merged

    def test_identical_snapshots_pass(self):
        self.assertEqual(evidence.compare_snapshots(self.base, self.after())["verdict"], "PASS")

    def test_job_state_change_fails(self):
        result = evidence.compare_snapshots(self.base, self.after(dispatchJobStates={"COMPLETED": 220, "DEAD_LETTERED": 1}))
        self.assertEqual(result["verdict"], "FAIL")
        self.assertEqual(result["gatedFieldsChanged"], ["dispatchJobStates"])

    def test_new_dead_letter_or_outbound_attempt_fails(self):
        self.assertEqual(evidence.compare_snapshots(self.base, self.after(deadLetterEntries=8))["verdict"], "FAIL")
        self.assertEqual(evidence.compare_snapshots(self.base, self.after(caseOutboundAttempts=1))["verdict"], "FAIL")

    def test_organic_case_activity_is_informational_only(self):
        result = evidence.compare_snapshots(self.base, self.after(caseEvents=105, departmentTasks=135))
        self.assertEqual(result["verdict"], "PASS")
        self.assertEqual(sorted(result["informationalDeltas"]), ["caseEvents", "departmentTasks"])

    def test_missing_gated_field_fails_closed(self):
        broken = dict(self.base)
        del broken["deadLetterEntries"]
        self.assertEqual(evidence.compare_snapshots(self.base, broken)["verdict"], "FAIL")


class ObserveScript(unittest.TestCase):
    def run_observe(self, responses, required="15"):
        with tempfile.TemporaryDirectory() as tmp:
            fixture = os.path.join(tmp, "responses.json")
            with open(fixture, "w", encoding="utf-8") as handle:
                json.dump(responses, handle)
            env = dict(os.environ, OBSERVE_RESPONSES_FILE=fixture, OBSERVE_EXPECTED_PER_MINUTE="2")
            result = subprocess.run(
                ["bash", OBSERVE, SINCE.isoformat(), required, "1", os.path.join(tmp, "out")],
                env=env, capture_output=True, text=True, check=False,
            )
            return result.returncode

    def test_exit_codes(self):
        self.assertEqual(self.run_observe(healthy_minutes(1, 15)), 0)
        self.assertEqual(self.run_observe(healthy_minutes(1, 5)), 3)
        self.assertEqual(self.run_observe(healthy_minutes(1, 5) + [row(6, 502, CLAIM_INVALID)]), 1)


if __name__ == "__main__":
    unittest.main()
