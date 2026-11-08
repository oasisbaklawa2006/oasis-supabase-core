#!/usr/bin/env python3
"""Regression tests for WA-100 protected release-job reconciliation."""
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from wa461_release_job_state import DEPLOY, EXISTING, PREFLIGHT, normalize

RUN = 42511185220

def job(name, conclusion, attempt=1, run_id=RUN):
    return {"id": attempt * 1000 + [PREFLIGHT, DEPLOY, EXISTING].index(name),
            "run_id": run_id, "run_attempt": attempt, "name": name,
            "status": "completed", "conclusion": conclusion}

def payload(*jobs, total=None):
    return {"total_count": len(jobs) if total is None else total, "jobs": list(jobs)}

class ReleaseJobsTests(unittest.TestCase):
    def setUp(self):
        self.pre = job(PREFLIGHT, "success")
        self.skip_d = job(DEPLOY, "skipped")
        self.skip_e = job(EXISTING, "skipped")

    def check_rejected(self, data, attempt=1):
        with self.assertRaises(ValueError):
            normalize(data, RUN, attempt)

    def test_recorded_real_preflight_only(self):
        actual = normalize(payload(self.pre, self.skip_d, self.skip_e), RUN, 1)
        self.assertEqual(actual["kind"], "preflight_only")

    def test_approved_deploy(self):
        data = payload(self.pre, job(DEPLOY, "success"), self.skip_e)
        self.assertEqual(normalize(data, RUN, 1)["kind"], "deployed")

    def test_certify_existing_never_implies_deploy(self):
        data = payload(self.pre, self.skip_d, job(EXISTING, "success"))
        self.assertEqual(normalize(data, RUN, 1)["kind"], "certify_existing_only")

    def test_failed_deploy_partial_rerun_reuses_successful_preflight(self):
        data = payload(self.pre, job(DEPLOY, "failure"), self.skip_e,
                       job(DEPLOY, "success", 2))
        actual = normalize(data, RUN, 2)
        self.assertEqual(actual["kind"], "deployed")
        self.assertEqual({x["name"]: x["run_attempt"] for x in actual["jobs"]}[PREFLIGHT], 1)
        self.assertEqual({x["name"]: x["run_attempt"] for x in actual["jobs"]}[DEPLOY], 2)

    def test_latest_failure_overrides_old_deploy_success(self):
        data = payload(self.pre, job(DEPLOY, "success"), self.skip_e,
                       job(DEPLOY, "failure", 2))
        self.check_rejected(data, 2)

    def test_latest_failed_preflight_overrides_old_preflight_success(self):
        data = payload(self.pre, job(DEPLOY, "success"), self.skip_e,
                       job(PREFLIGHT, "failure", 2))
        self.check_rejected(data, 2)

    def test_ambiguous_both_success(self):
        self.check_rejected(payload(self.pre, job(DEPLOY, "success"), job(EXISTING, "success")))

    def test_job_from_other_run(self):
        self.check_rejected(payload(self.pre, self.skip_d, job(EXISTING, "skipped", run_id=123)))

    def test_duplicate_attempt_is_not_selected_arbitrarily(self):
        self.check_rejected(payload(self.pre, self.skip_d, job(DEPLOY, "success"), self.skip_e))

    def test_missing_history(self):
        self.check_rejected(payload(self.pre, self.skip_d, self.skip_e, total=4))

    def test_missing_preflight(self):
        self.check_rejected(payload(self.skip_d, self.skip_e))

    def test_future_attempt(self):
        self.check_rejected(payload(self.pre, self.skip_e, job(DEPLOY, "success", 2)), 1)

    def test_incomplete_job(self):
        d = job(DEPLOY, "success")
        d["status"] = "in_progress"
        self.check_rejected(payload(self.pre, d, self.skip_e))

    def test_unknown_additional_job(self):
        self.check_rejected(payload(self.pre, self.skip_d, self.skip_e,
                                    job("unexpected", "success")))

if __name__ == "__main__":
    unittest.main(verbosity=2)
