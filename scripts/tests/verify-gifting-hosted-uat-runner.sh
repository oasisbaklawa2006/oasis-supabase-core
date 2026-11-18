#!/usr/bin/env bash
# Regression test for the Gifting receiver hosted UAT runner and its manual workflow.
#
# 1. Guard unit tests (python unittest): the runner refuses anything that is not the single reviewed,
#    isolated, non-persistent preview; refuses production refs and foreign credentials; refuses to run
#    outside a manual dispatch; and its redaction scan blocks any credential from reaching evidence.
# 2. Workflow contract: manual dispatch only, protected environment, explicit confirmation, one secret,
#    read-only token, evidence-only artifact.
# 3. The REAL preview-secrets guard rejects mutations that would let the workflow run on pull requests or
#    read its secret without the protected environment. The guard itself is never modified.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

workflow=".github/workflows/gifting-receiver-hosted-uat.yml"
runner="scripts/uat/gifting-enquiry-receiver-hosted-uat.py"
guard="scripts/check-preview-edge-runtime-secrets-config.sh"
targets="docs/programme/gifting-uat-targets.json"

fail() { echo "GIFTING HOSTED UAT RUNNER TEST FAILURE: $*" >&2; exit 1; }

[[ -f "$workflow" && -f "$runner" && -f "$targets" ]] || fail "workflow, runner and target allow-list must exist"

# ---------------------------------------------------------------------------
# 1. Runner guard unit tests
# ---------------------------------------------------------------------------
RUNNER="$runner" TARGETS="$targets" python3 - <<'PY'
import importlib.util, json, os, unittest
from unittest import mock
from pathlib import Path

spec = importlib.util.spec_from_file_location("uat", os.environ["RUNNER"])
uat = importlib.util.module_from_spec(spec)
spec.loader.exec_module(uat)
targets = json.loads(Path(os.environ["TARGETS"]).read_text())
GOOD = targets["targets"][0]["ref"]
PROD = targets["forbidden_refs"][0]


class Guards(unittest.TestCase):
    def test_allow_listed_preview_is_accepted(self):
        self.assertEqual(uat.validate_target(GOOD, targets)["ref"], GOOD)

    def test_unlisted_malformed_and_production_refs_are_refused(self):
        for ref in ("abcdefghijklmnopqrst", "short", "UPPERCASEUPPERCASEUPP", "", GOOD + "x", PROD):
            with self.assertRaises(uat.UatAbort, msg=ref):
                uat.validate_target(ref, targets)

    def test_a_forbidden_ref_wins_even_if_someone_allow_lists_it(self):
        sneaky = {"targets": [{"ref": PROD, "persistent": False, "with_data": False}], "forbidden_refs": [PROD]}
        with self.assertRaises(uat.UatAbort):
            uat.validate_target(PROD, sneaky)

    def test_persistent_or_data_bearing_entries_are_refused(self):
        for entry in ({"ref": GOOD, "persistent": True, "with_data": False}, {"ref": GOOD, "persistent": False, "with_data": True},
                      {"ref": GOOD}):
            with self.assertRaises(uat.UatAbort):
                uat.validate_target(GOOD, {"targets": [entry], "forbidden_refs": []})

    def test_committed_allow_list_is_safe(self):
        self.assertIn(PROD, targets["forbidden_refs"])
        for entry in targets["targets"]:
            self.assertIs(entry["persistent"], False)
            self.assertIs(entry["with_data"], False)
            self.assertRegex(entry["ref"], r"^[a-z]{20}$")
            self.assertNotEqual(entry["ref"], PROD)

    def test_database_url_must_belong_to_the_ref(self):
        direct = uat.parse_db_url(f"postgresql://postgres:pw@db.{GOOD}.supabase.co:5432/postgres")
        uat.assert_db_matches_ref(direct, GOOD)
        pooler = uat.parse_db_url(f"postgresql://postgres.{GOOD}:pw@aws-0-ap-south-1.pooler.supabase.com:6543/postgres")
        uat.assert_db_matches_ref(pooler, GOOD)
        for url in (f"postgresql://postgres:pw@db.{PROD}.supabase.co:5432/postgres",
                    f"postgresql://postgres.{PROD}:pw@aws-0-ap-south-1.pooler.supabase.com:6543/postgres",
                    "postgresql://postgres:pw@localhost:5432/postgres"):
            with self.assertRaises(uat.UatAbort, msg=url):
                uat.assert_db_matches_ref(uat.parse_db_url(url), GOOD)
        for bad in ("", "mysql://x@y/z", "not a url"):
            with self.assertRaises(uat.UatAbort):
                uat.parse_db_url(bad)

    def test_function_url_is_derived_from_the_ref_only(self):
        self.assertEqual(uat.function_url(GOOD), f"https://{GOOD}.supabase.co/functions/v1/gifting-enquiries")

    def test_redaction_scan_blocks_tokens_and_known_secrets(self):
        token = "oc_preview_" + "ab12" * 12
        self.assertTrue(uat.scan_for_secrets(f"leak {token} here", []))
        self.assertTrue(uat.scan_for_secrets("pw is hunter2hunter2", ["hunter2hunter2"]))
        self.assertTrue(uat.scan_for_secrets("oc_staging_" + "0123456789abcdef0123", []))
        self.assertEqual(uat.scan_for_secrets("PASS first delivery 201, enquiryId 3e9aece9", ["hunter2hunter2"]), [])

    def _args(self, **kw):
        ns = mock.Mock(local_test=False, ref=GOOD, evidence_dir="x", function_url=None, ca_file=None)
        for k, v in kw.items():
            setattr(ns, k, v)
        return ns

    def test_local_test_mode_is_refused_in_github_actions_and_without_opt_in(self):
        with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GIFTING_UAT_LOCAL_TEST": "1"}, clear=False):
            with self.assertRaises(uat.UatAbort):
                uat.run(self._args(local_test=True))
        env = {k: v for k, v in os.environ.items() if k not in ("GIFTING_UAT_LOCAL_TEST", "GITHUB_ACTIONS")}
        with mock.patch.dict(os.environ, env, clear=True):
            with self.assertRaises(uat.UatAbort):
                uat.run(self._args(local_test=True))

    def test_hosted_run_is_refused_unless_manually_dispatched(self):
        for event in ("pull_request", "push", "schedule", ""):
            with mock.patch.dict(os.environ, {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": event,
                                              "GIFTING_UAT_DB_URL": f"postgresql://postgres:pw@db.{GOOD}.supabase.co/postgres"}):
                with self.assertRaises(uat.UatAbort, msg=event):
                    uat.run(self._args())

    def test_a_missing_or_foreign_credential_aborts_before_any_database_call(self):
        base = {"GITHUB_ACTIONS": "true", "GITHUB_EVENT_NAME": "workflow_dispatch"}
        with mock.patch.dict(os.environ, {**base, "GIFTING_UAT_DB_URL": ""}):
            with self.assertRaises(uat.UatAbort):
                uat.run(self._args())
        with mock.patch.dict(os.environ, {**base, "GIFTING_UAT_DB_URL": f"postgresql://postgres:pw@db.{PROD}.supabase.co/postgres"}):
            with mock.patch.object(uat, "Db", side_effect=AssertionError("database must not be touched")):
                with self.assertRaises(uat.UatAbort):
                    uat.run(self._args())


suite = unittest.defaultTestLoader.loadTestsFromTestCase(Guards)
result = unittest.TextTestRunner(verbosity=0).run(suite)
raise SystemExit(0 if result.wasSuccessful() else 1)
PY
echo "runner guard unit tests: ok"

# ---------------------------------------------------------------------------
# 2. Workflow contract
# ---------------------------------------------------------------------------
trigger_block() { awk '/^on:/ {on = 1; next} on && /^[^[:space:]#]/ {exit} on {print}' "$1"; }
triggers="$(trigger_block "$workflow" | grep -E '^  [A-Za-z_]+:' | sed 's/[[:space:]]*:.*//; s/^[[:space:]]*//' | sort -u | tr '\n' ' ')"
[[ "$triggers" == "workflow_dispatch " ]] || fail "workflow must be manual-dispatch only (found: ${triggers:-none})"
grep -Eq '^    environment:[[:space:]]*gifting-preview-uat[[:space:]]*$' "$workflow" || fail "job must bind the protected gifting-preview-uat environment"
grep -Fq "inputs.confirm == 'RUN-SYNTHETIC-UAT'" "$workflow" || fail "job must require the explicit confirmation phrase"
grep -Eq '^[[:space:]]+contents:[[:space:]]*read[[:space:]]*$' "$workflow" || fail "token must be read-only"
if grep -Eq 'contents:[[:space:]]*write|secrets:[[:space:]]*inherit|workflow_call|pull_request|workflow_run' "$workflow"; then
  fail "workflow must not write, inherit secrets, be reusable, or run on pull-request/workflow-run events"
fi
secrets_used="$(grep -Eo 'secrets\.[A-Z][A-Z0-9_]+' "$workflow" | sort -u | tr '\n' ' ')"
[[ "$secrets_used" == "secrets.GIFTING_UAT_DB_URL " ]] || fail "only GIFTING_UAT_DB_URL may be read (found: $secrets_used)"
grep -Fq 'persist-credentials: false' "$workflow" || fail "checkout must not persist credentials"
grep -Fq 'path: uat-evidence/' "$workflow" || fail "only the evidence directory may be uploaded"
awk '/Run the synthetic UAT/{r=NR} /Keep the redacted evidence/{u=NR} END{exit !(r && u && r<u)}' "$workflow" || fail "evidence upload must follow the runner"
echo "workflow contract: ok"

# ---------------------------------------------------------------------------
# 3. The real preview-secrets guard rejects unsafe mutations
# ---------------------------------------------------------------------------
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

fresh_copy() {
  local dir="$work/$1"
  mkdir -p "$dir"
  git ls-files --cached --others --exclude-standard -z | tar --null -T - -cf - | tar -xf - -C "$dir"
  git -C "$dir" init -q
  # Isolate this test from an unrelated, separately tracked workflow-boundary defect (Core #558): only while
  # that file still carries a pull-request trigger AND an environment, drop it from the throw-away copy.
  local offender="$dir/.github/workflows/wa100-admin-draft-protected-cutover.yml"
  if [[ -f "$offender" ]] && grep -Eq '^  pull_request:' "$offender"; then rm -f "$offender"; fi
  echo "$dir"
}

pristine="$(fresh_copy pristine)"
(cd "$pristine" && bash "$guard" >/dev/null) || fail "the real guard must accept the workflow as committed"
echo "guard accepts the committed workflow"

expect_guard_rejects() { # name mutation-command pattern
  local dir out
  dir="$(fresh_copy "$1")"
  (cd "$dir" && eval "$2")
  if out="$(cd "$dir" && bash "$guard" 2>&1)"; then fail "guard accepted mutation: $1"; fi
  grep -Fq "$3" <<<"$out" || fail "guard rejected '$1' for the wrong reason: $out"
  echo "guard rejects: $1"
}

expect_guard_rejects \
  "pull-request trigger added to the UAT workflow" \
  "python3 - <<'PYM'
p='$workflow'
s=open(p).read()
s=s.replace('on:\n  workflow_dispatch:','on:\n  pull_request:\n    branches: [main]\n  workflow_dispatch:',1)
open(p,'w').write(s)
PYM" \
  "must not bind a GitHub environment"

expect_guard_rejects \
  "database secret read without the protected environment" \
  "sed -i '/^    environment: gifting-preview-uat\$/d' $workflow" \
  "without a protected environment"

expect_guard_rejects \
  "untrusted-code trigger on the UAT workflow" \
  "sed -i 's/^  workflow_dispatch:\$/  pull_request_target:\n  workflow_dispatch:/' $workflow" \
  "must not use pull_request_target"

echo "Gifting hosted UAT runner regression verified."
