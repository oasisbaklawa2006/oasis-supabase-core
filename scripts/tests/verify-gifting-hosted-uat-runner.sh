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
import argparse, importlib.util, json, os, tempfile, unittest
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


    # -- acceptance must not be satisfiable by a receiver that returns no identifier (CodeRabbit finding on #560)
    def _uat(self):
        u = uat.Uat(mock.Mock(), "https://example.invalid/fn", None, True, "t1")
        u.tokens = {"OK": "tok"}
        return u

    def _delivery_results(self, responses, rows=1):
        u = self._uat()
        lead, body = "11111111-1111-4111-8111-111111111111", uat.payload()
        sequence = iter(responses)
        u.post = lambda *a, **k: next(sequence)
        u.rows = lambda _lead: rows
        u.db.run.return_value = body["message"]
        u.delivery(lead, body)
        return {r["scenario"]: r["pass"] for r in u.results}, lead

    def test_a_receiver_that_omits_enquiry_id_is_not_accepted(self):
        lead = "11111111-1111-4111-8111-111111111111"
        accepted = {"status": "accepted", "queue": "gifting_enquiries", "sourceLeadId": lead}
        # Every response omits enquiryId: replay compares None == None, which used to pass.
        results, _ = self._delivery_results([(201, accepted), (200, {"replayed": True}), (409, {}), (200, {"replayed": True})])
        for name in ("delivery: first delivery -> 201 accepted", "replay: identical replay -> 200 with the same enquiryId",
                     "replay: exact replay still succeeds after a rejected conflict"):
            self.assertFalse(results[name], name)

    def test_a_receiver_that_returns_a_real_enquiry_id_is_accepted(self):
        lead = "11111111-1111-4111-8111-111111111111"
        accepted = {"status": "accepted", "queue": "gifting_enquiries", "sourceLeadId": lead, "enquiryId": "e1"}
        results, _ = self._delivery_results([(201, accepted), (200, {"replayed": True, "enquiryId": "e1"}), (409, {}),
                                             (200, {"replayed": True, "enquiryId": "e1"})])
        self.assertTrue(all(results[n] for n in results if n.startswith(("delivery: first", "replay:"))), results)

    def test_concurrency_requires_exactly_one_real_enquiry_id(self):
        def run(ids):
            u = self._uat()
            u.rows = lambda _lead: 1
            u.post = lambda *a, **k: (201, {"enquiryId": ids.pop()} if ids else {})
            u.concurrency("lead", uat.payload())
            return {r["scenario"]: r["pass"] for r in u.results}["concurrency: exactly one row and one enquiryId"]
        self.assertFalse(run([]))                    # no enquiryId at all -> {None}, used to pass
        self.assertFalse(run(["a", "b"] * 10))       # two different ids
        self.assertTrue(run(["same"] * 20))          # one real id

    # -- an execution failure after provisioning is a failed run that still cleans up and writes evidence
    def test_an_execution_failure_after_provisioning_still_cleans_up_and_writes_evidence(self):
        with tempfile.TemporaryDirectory() as out:
            args = argparse.Namespace(ref=None, evidence_dir=out, local_test=True, function_url="https://x.invalid", ca_file=None)
            with mock.patch.object(uat, "build_context", return_value=({"password": "pw"}, "local-test", "https://x.invalid", None, True)), \
                 mock.patch.object(uat, "Db"), mock.patch.object(uat.Uat, "preflight"), \
                 mock.patch.object(uat.Uat, "provision", side_effect=OSError("secret-looking-detail")), \
                 mock.patch.object(uat.Uat, "cleanup", return_value=True) as cleanup:
                code = uat.run(args)
            self.assertEqual(code, 1)
            cleanup.assert_called_once()
            evidence = Path(out, "evidence.json").read_text()
            self.assertIn("run: execution failed after provisioning", evidence)
            self.assertIn("OSError", evidence)
            self.assertNotIn("secret-looking-detail", evidence)   # only the exception type is recorded

    def test_a_redaction_failure_after_provisioning_is_exit_1_with_evidence_withheld(self):
        with tempfile.TemporaryDirectory() as out:
            with mock.patch.object(uat, "build_context", return_value=({"password": "pw"}, "local-test", "https://x.invalid", None, True)), \
                 mock.patch.object(uat, "Db"), mock.patch.object(uat.Uat, "preflight"), \
                 mock.patch.object(uat.Uat, "provision", return_value=["local-test"]), \
                 mock.patch.object(uat.Uat, "credentials"), mock.patch.object(uat.Uat, "delivery"), \
                 mock.patch.object(uat.Uat, "concurrency"), mock.patch.object(uat.Uat, "marketing_and_validation"), \
                 mock.patch.object(uat.Uat, "cleanup", return_value=True), \
                 mock.patch.object(uat, "scan_for_secrets", return_value=["leak"]):
                code = uat.main(["--local-test", "--function-url", "https://x.invalid", "--evidence-dir", out])
            self.assertEqual(code, 1)
            self.assertFalse(Path(out, "evidence.json").exists())


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
# Every GITHUB_TOKEN permission (workflow level AND job level) must be read-only: contents: read is required and no
# scope may be `write`, nor `write-all`. (Checking only `contents: write` let `issues: write` through.)
permissions_read_only() {
  # Fail closed: parse the YAML (quoting/escapes cannot hide a write scope). The WORKFLOW must declare explicit
  # read-only permissions with contents: read (a missing block would inherit the repository default, which may
  # be read/write), and any job-level permissions must also be read/none.
  python3 -c 'import yaml' 2>/dev/null || { echo "PyYAML is required to verify workflow permissions" >&2; return 1; }
  python3 - "$1" <<'PYP'
import sys, yaml
try:
    doc = yaml.safe_load(open(sys.argv[1]))
except yaml.YAMLError:
    sys.exit(1)  # unparseable workflow is never accepted
def scopes_ok(p):
    return isinstance(p, dict) and all(str(v) in ("read", "none") for v in p.values())
top = doc.get("permissions") if isinstance(doc, dict) else None
if not (scopes_ok(top) and str(top.get("contents")) == "read"):
    sys.exit(1)
for job in (doc.get("jobs") or {}).values():
    jp = job.get("permissions")
    if jp is not None and not (scopes_ok(jp) or jp == "none"):
        sys.exit(1)
sys.exit(0)
PYP
}
# Prints the `path:` of EVERY upload-artifact step ("<none>" when a step sets none, i.e. the default).
upload_paths() {
  awk '
    function flush(  i) { if (up) { if (np == 0) print "<none>"; for (i = 1; i <= np; i++) print paths[i] } up = 0; np = 0 }
    /^[[:space:]]*-[[:space:]]/ { flush() }
    /uses:[[:space:]]*["'"'"']?actions\/upload-artifact/ { up = 1 }
    /^[[:space:]]+path:[[:space:]]*/ { v = $0; sub(/^[[:space:]]+path:[[:space:]]*/, "", v); sub(/[[:space:]]+$/, "", v); paths[++np] = v }
    END { flush() }' "$1"
}
# At least one upload, and every upload is the evidence directory only.
uploads_evidence_only() {
  local out; out="$(upload_paths "$1")"
  [[ -n "$out" ]] && ! grep -qvx 'uat-evidence/' <<<"$out"
}
permissions_read_only "$workflow" || fail "every token permission must be read-only (no write scope, no write-all)"
if grep -Eq 'contents:[[:space:]]*write|secrets:[[:space:]]*inherit|workflow_call|pull_request|workflow_run' "$workflow"; then
  fail "workflow must not write, inherit secrets, be reusable, or run on pull-request/workflow-run events"
fi
secrets_used="$(grep -Eo 'secrets\.[A-Z][A-Z0-9_]+' "$workflow" | sort -u | tr '\n' ' ')"
[[ "$secrets_used" == "secrets.GIFTING_UAT_DB_URL " ]] || fail "only GIFTING_UAT_DB_URL may be read (found: $secrets_used)"
grep -Fq 'persist-credentials: false' "$workflow" || fail "checkout must not persist credentials"
uploads_evidence_only "$workflow" || fail "every artifact upload must be the evidence directory only"
# Negative controls: the two checks above must REJECT these mutations, so they cannot be satisfied vacuously.
mut="$(mktemp -d)"
sed 's/^  contents: read$/  contents: read\n  issues: write/' "$workflow" > "$mut/wf-issues-write.yml"
sed 's/^permissions:$/permissions: write-all/' "$workflow" > "$mut/wf-write-all.yml"
sed '/^    runs-on: ubuntu-24.04$/a\    permissions:\n      pull-requests: write' "$workflow" > "$mut/wf-job-write.yml"
{ cat "$workflow"; printf '      - name: Upload everything\n        uses: actions/upload-artifact@deadbeef\n        with:\n          name: all\n          path: .\n'; } > "$mut/wf-extra-upload.yml"
{ cat "$workflow"; printf '      - name: Upload with the default path\n        uses: actions/upload-artifact@deadbeef\n        with:\n          name: all\n'; } > "$mut/wf-default-path.yml"
sed 's/^  contents: read$/  contents: read\n  issues: "write"/' "$workflow" > "$mut/wf-dq-write.yml"
sed "s/^  contents: read\$/  contents: read\n  issues: 'write'/" "$workflow" > "$mut/wf-sq-write.yml"
sed '/^    runs-on: ubuntu-24.04$/a\    permissions:\n      pull-requests: "write"' "$workflow" > "$mut/wf-job-dq-write.yml"
{ cat "$workflow"; printf '      - name: Upload everything\n        uses: "actions/upload-artifact@deadbeef"\n        with:\n          name: all\n          path: .\n'; } > "$mut/wf-quoted-upload.yml"
sed 's/^  contents: read$/  contents: read\n  "issues": write/' "$workflow" > "$mut/wf-quoted-key.yml"
sed "s/^  contents: read\$/  contents: read\n  'issues': 'write'/" "$workflow" > "$mut/wf-sq-key-value.yml"
sed "/^    runs-on: ubuntu-24.04\$/a\\    permissions:\n      pull-requests: 'write'" "$workflow" > "$mut/wf-job-sq-write.yml"
sed '/^    runs-on: ubuntu-24.04$/a\    permissions:\n      "pull-requests": write' "$workflow" > "$mut/wf-job-quoted-key.yml"
sed 's/^  contents: read$/  contents: read\n  issues: "wr\\u0069te"/' "$workflow" > "$mut/wf-escaped-write.yml"
python3 - "$workflow" "$mut" <<'PYM'
import re, sys
src = open(sys.argv[1]).read(); out = sys.argv[2]
open(out + "/wf-no-top-permissions.yml", "w").write(src.replace("permissions:\n  contents: read\n", "", 1))
open(out + "/wf-empty-top-permissions.yml", "w").write(src.replace("permissions:\n  contents: read\n", "permissions: {}\n", 1))
open(out + "/wf-top-no-contents.yml", "w").write(src.replace("permissions:\n  contents: read\n", "permissions:\n  actions: read\n", 1))
PYM
for f in wf-issues-write wf-write-all wf-job-write wf-dq-write wf-sq-write wf-job-dq-write wf-quoted-key wf-sq-key-value wf-job-sq-write wf-job-quoted-key wf-escaped-write wf-no-top-permissions wf-empty-top-permissions wf-top-no-contents; do
  ! permissions_read_only "$mut/$f.yml" || fail "permission check accepted a writable scope ($f)"
done
for f in wf-extra-upload wf-default-path wf-quoted-upload; do
  ! uploads_evidence_only "$mut/$f.yml" || fail "upload check accepted a non-evidence upload ($f)"
done
permissions_read_only "$workflow" && uploads_evidence_only "$workflow" || fail "positive control: the real workflow must still pass"
rm -rf "$mut"
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
