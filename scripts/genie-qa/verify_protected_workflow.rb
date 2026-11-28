#!/usr/bin/env ruby
# Parse the effective GitHub Actions YAML, not comments or string fragments.
# Fail closed when any QA-only release control or dispatch isolation is missing.
require 'psych'

def require_control(condition, reason)
  abort("GENIE_QA_WORKFLOW_DENIED: #{reason}") unless condition
end

begin
  workflow = Psych.safe_load_file(ARGV.fetch(0), aliases: false)
rescue StandardError
  abort("GENIE_QA_WORKFLOW_DENIED: unreadable or invalid YAML")
end
require_control(workflow.is_a?(Hash), 'workflow mapping required')
# YAML 1.1 represents an unquoted "on" key as true; GitHub uses this spelling.
events = workflow['on'] || workflow[true]
require_control(events.is_a?(Hash) && events.keys == ['workflow_dispatch'],
                'manual dispatch must be the sole trigger')
inputs = events.dig('workflow_dispatch', 'inputs')
require_control(inputs.is_a?(Hash), 'dispatch inputs required')
mode = inputs['mode']
require_control(mode.is_a?(Hash) && mode['type'] == 'choice' &&
                mode['options'] == %w[preflight apply preflight-forward apply-forward] && mode['default'] == 'preflight',
                'preflight/apply/preflight-forward/apply-forward input contract changed')
require_control(inputs['expected_head_sha'].is_a?(Hash) &&
                inputs['expected_head_sha']['required'] == true,
                'exact source SHA input required')
require_control(inputs['change_reference'].is_a?(Hash) &&
                inputs['change_reference']['required'] == true,
                'change reference required')

require_control(workflow['permissions'] == {'contents' => 'read'},
                'workflow permissions must be read-only')
jobs = workflow['jobs']
require_control(jobs.is_a?(Hash) && jobs.keys == ['schema'], 'only canonical schema job allowed')
job = jobs['schema']
require_control(job.is_a?(Hash), 'schema job required')
expected_gate = "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'"
require_control(job['if'] == expected_gate, 'repository and protected main gate changed')
require_control(job['environment'] == 'genie-qa-bootstrap', 'protected QA environment missing')
require_control(job['runs-on'] == 'ubuntu-24.04', 'PG17-compatible runner required')
env = job['env']
require_control(env.is_a?(Hash), 'QA environment binding required')
require_control(env['GENIE_QA_PROJECT_REF'] == 'skhpmltfjgqitntkmclb', 'QA project changed')
require_control(env['GENIE_QA_RUN_MODE'] == '$' + '{{ inputs.mode }}', 'run mode changed')
require_control(env['GENIE_QA_EXPECTED_SHA'] == '$' + '{{ inputs.expected_head_sha }}', 'head SHA binding changed')
require_control(env['GENIE_QA_DATABASE_URL'] == '$' + '{{ secrets.GENIE_QA_DATABASE_URL }}', 'QA DB secret changed')
require_control(env['GENIE_QA_CA_CERT_PEM'] == '$' + '{{ secrets.GENIE_QA_CA_CERT_PEM }}', 'QA root CA secret changed')
require_control(env['GENIE_QA_APPROVAL_PHRASE'] == '$' + '{{ inputs.authorization }}', 'apply approval input changed')
require_control(env['GENIE_QA_FORWARD_LEDGER_COUNT'] == '$' + '{{ inputs.qa_ledger_count }}' &&
                env['GENIE_QA_FORWARD_LEDGER_MAX'] == '$' + '{{ inputs.qa_ledger_max_version }}' &&
                env['GENIE_QA_FORWARD_TOTAL'] == '$' + '{{ inputs.expected_total_migrations }}',
                'forward-apply ledger bindings changed')

steps = job['steps']
require_control(steps.is_a?(Array), 'workflow steps required')
# Mandatory recovery gates must never be made non-blocking, even by an expression.
require_control(([workflow, job] + steps).all? { |scope| scope.is_a?(Hash) && !scope.key?('continue-on-error') },
                'failure suppression forbidden')
def named_step(steps, name)
  matches = steps.select { |step| step.is_a?(Hash) && step['name'] == name }
  require_control(matches.length == 1, "missing or duplicate step: #{name}")
  matches.first
end
def active_line?(run, line)
  run.is_a?(String) && run.lines.any? { |part| part.strip == line }
end

identity = named_step(steps, 'Check immutable source and QA-only target')
require_control(active_line?(identity['run'], 'python3 scripts/genie-qa/verify_qa_target.py'),
                'target validator not executed')
require_control(active_line?(identity['run'], 'python3 scripts/genie-qa/build_no_egress_overlay.py --output "$RUNNER_TEMP/genie-qa-overlay"'),
                'pinned overlay not constructed')
require_control(active_line?(identity['run'], 'python3 scripts/genie-qa/verify_no_outbound.py "$RUNNER_TEMP/genie-qa-overlay/supabase/migrations"'),
                'initial egress scanner missing')

tls = named_step(steps, 'Require trusted QA TLS CA and prepare credential-free logs')
require_control(active_line?(tls['run'], 'echo "PGSSLMODE=verify-full" >> "$GITHUB_ENV"'),
                'verified remote TLS requirement missing')
require_control(active_line?(tls['run'], 'echo "PGSSLROOTCERT=$RUNNER_TEMP/genie-qa-ca.crt" >> "$GITHUB_ENV"'),
                'trusted remote CA binding missing')

local = named_step(steps, 'Prove exact Git baseline + full local clean migration replay and contracts')
local_run = local['run']
require_control(local_run.is_a?(String) && local_run.include?('env -u SUPABASE_WORKDIR -u PGSSLMODE -u PGSSLROOTCERT'),
                'local replay must isolate overlay and remote TLS')
require_control(local_run.include?('bash scripts/verify-local-schema-release-readiness.sh'),
                'canonical local replay missing')

dry = named_step(steps, 'Dry-run the full QA-only canonical migration sequence')
require_control(dry['if'].nil?, 'dry-run may not be conditional on apply')
require_control(dry['run'].is_a?(String) && dry['run'].include?('supabase db push --db-url "$GENIE_QA_DATABASE_URL" --dry-run'),
                'remote dry-run must be present')
require_control(active_line?(dry['run'], 'cd "$SUPABASE_WORKDIR"'),
                'dry-run must use verified overlay')

apply = named_step(steps, 'Explicitly authorized QA-only apply (never production)')
require_control(apply['if'] == "inputs.mode == 'apply'", 'apply step must be apply-only')
run = apply['run']
require_control(run.is_a?(String), 'apply body missing')
require_control(active_line?(run, 'test "$GENIE_QA_APPROVAL_PHRASE" = ' + "'AUTHORIZE-GENIE-QA-CANONICAL-BOOTSTRAP'"),
                'owner authorization phrase not enforced')
require_control(active_line?(run, 'python3 scripts/genie-qa/verify_no_outbound.py "$SUPABASE_WORKDIR/supabase/migrations"'),
                'pre-apply egress scanner missing')
require_control(active_line?(run, 'cd "$SUPABASE_WORKDIR"'), 'apply must use verified overlay')
require_control(run.include?('supabase db push --db-url "$GENIE_QA_DATABASE_URL" --yes'),
                'QA apply command changed')
require_control(run.include?('GENIE_QA_EGRESS_AFTER_APPLY') &&
                run.include?('test "$egress_after" = "safe"'),
                'post-apply egress proof missing')
require_control(run.include?('GENIE_QA_PT409_MISSING'), 'post-apply PT409 check missing')

# Empty modes require an empty project; both forward modes require an exact ledger prefix.
clean = named_step(steps, 'Prove QA database is clean before any remote migration')
require_control(clean['if'] == "inputs.mode == 'preflight' || inputs.mode == 'apply'", 'empty-QA proof must guard apply and preflight')
prefix = named_step(steps, 'Prove QA ledger is an exact prefix of the reviewed sequence (forward mode only)')
require_control(prefix['if'] == "inputs.mode == 'preflight-forward' || inputs.mode == 'apply-forward'", 'ledger prefix proof must be forward-only')
require_control(prefix['run'].is_a?(String) &&
                prefix['run'].include?('GENIE_QA_FORWARD_LEDGER_NOT_A_PREFIX') &&
                prefix['run'].include?('cmp -s "$RUNNER_TEMP/qa-expected-prefix.txt" "$RUNNER_TEMP/qa-recorded-versions.txt"') &&
                prefix['run'].include?('GENIE_QA_FORWARD_NOTHING_TO_APPLY'),
                'forward ledger prefix proof incomplete')
require_control(steps.index(prefix) < steps.index(dry), 'prefix proof must precede the dry-run')

forward = named_step(steps, 'Explicitly authorized QA-only forward apply (never production)')
require_control(forward['id'] == 'forward_apply', 'forward apply step ID changed')
require_control(forward['if'] == "inputs.mode == 'apply-forward'", 'forward apply step must be apply-forward-only')
frun = forward['run']
require_control(frun.is_a?(String), 'forward apply body missing')
require_control(active_line?(frun, 'test "$GENIE_QA_APPROVAL_PHRASE" = ' + "'AUTHORIZE-GENIE-QA-FORWARD-APPLY'"),
                'forward authorization phrase not enforced')
require_control(active_line?(frun, 'python3 scripts/genie-qa/verify_no_outbound.py "$SUPABASE_WORKDIR/supabase/migrations"'),
                'forward pre-apply egress scanner missing')
require_control(active_line?(frun, 'cd "$SUPABASE_WORKDIR"'), 'forward apply must use verified overlay')
require_control(frun.include?('supabase db push --db-url "$GENIE_QA_DATABASE_URL" --yes'), 'QA forward apply command changed')
require_control(frun.include?('GENIE_QA_EGRESS_AFTER_APPLY') && frun.include?('test "$egress_after" = "safe"'),
                'forward post-apply egress proof missing')
require_control(frun.include?('GENIE_QA_LEDGER_INCOMPLETE') &&
                frun.include?('cmp -s "$RUNNER_TEMP/qa-source-versions.txt" "$RUNNER_TEMP/qa-recorded-after.txt"'),
                'forward post-apply full-ledger proof missing')
require_control(frun.include?('GENIE_QA_PT409_MISSING'), 'forward post-apply PT409 check missing')

backup = named_step(steps, 'Capture encrypted QA recovery archive and preservation baseline')
retain = named_step(steps, 'Retain encrypted QA recovery archive')
check = named_step(steps, 'Verify recovery archive retention and unchanged protected data')
preserve = named_step(steps, 'Verify protected data survived forward apply')
forward_if = "inputs.mode == 'preflight-forward' || inputs.mode == 'apply-forward'"
client = named_step(steps, 'Provision and verify PostgreSQL 17 client tools')
require_control(client['if'] == forward_if &&
                active_line?(client['run'], 'env -u GENIE_QA_DATABASE_URL -u GENIE_QA_CA_CERT_PEM bash scripts/genie-qa/install_pg17_client.sh'),
                'PG17 client provisioning missing or incorrectly scoped')
require_control([backup, retain, check].all? { |s| s['if'] == forward_if },
                'forward recovery checks must guard both forward modes')
require_control(backup.dig('env', 'GENIE_QA_BACKUP_PASSPHRASE') == '$' + '{{ secrets.GENIE_QA_BACKUP_PASSPHRASE }}' &&
                active_line?(backup['run'], 'bash scripts/genie-qa/capture_forward_backup.sh'),
                'encrypted backup capture or scoped recovery key missing')
require_control(retain['uses'] == 'actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02' &&
                retain['with']['if-no-files-found'] == 'error' &&
                retain['with']['path'].lines.map(&:strip) == [
                  '$' + '{{ runner.temp }}/genie-qa-encrypted-backup/backup.tar.gpg',
                  '$' + '{{ runner.temp }}/genie-qa-encrypted-backup/backup.tar.gpg.sha256'
                ], 'only encrypted recovery artifacts may be uploaded')
check_run = check['run']
require_control(check_run.is_a?(String) &&
                active_line?(check_run, 'set -euo pipefail') &&
                active_line?(check_run, '[[ "$QA_ARTIFACT_ID" =~ ^[1-9][0-9]*$ ]] || { echo "::error::QA_BACKUP_UPLOAD_UNVERIFIED"; exit 1; }') &&
                active_line?(check_run, '[[ "$QA_ARTIFACT_DIGEST" =~ ^(sha256:)?[0-9a-f]{64}$ ]] || { echo "::error::QA_BACKUP_DIGEST_UNVERIFIED"; exit 1; }') &&
                active_line?(check_run, 'bash scripts/genie-qa/forward_preservation.sh "$RUNNER_TEMP/qa-preservation-before.json"'),
                'durable backup and preservation proof missing')
fingerprint_guard = [
  'actual="$(sha256sum "$RUNNER_TEMP/qa-preservation-before.json" | cut -d ' + "' '" + ' -f1)"',
  'if [[ "$GENIE_QA_RUN_MODE" == apply-forward ]]; then',
  'test "$actual" = "$GENIE_QA_VERIFIED_STATE_SHA256" || { echo "::error::QA_REVIEWED_BASELINE_CHANGED"; exit 1; }',
  'fi'
]
require_control(check_run.lines.map(&:strip).each_cons(fingerprint_guard.length).any? { |lines| lines == fingerprint_guard },
                'executable reviewed fingerprint guard missing')
require_control(retain['id'] == 'forward_backup_upload' &&
                check.dig('env', 'QA_ARTIFACT_ID') == '$' + '{{ steps.forward_backup_upload.outputs.artifact-id }}' &&
                check.dig('env', 'QA_ARTIFACT_DIGEST') == '$' + '{{ steps.forward_backup_upload.outputs.artifact-digest }}',
                'recovery artifact output bindings changed')
require_control(steps.index(dry) < steps.index(client) && steps.index(client) < steps.index(backup) && steps.index(backup) < steps.index(retain) &&
                steps.index(retain) < steps.index(check) && steps.index(check) < steps.index(forward) &&
                steps.index(forward) < steps.index(preserve), 'forward recovery gates ordered incorrectly')
require_control(preserve['if'] == "always() && inputs.mode == 'apply-forward' && (steps.forward_apply.outcome == 'success' || steps.forward_apply.outcome == 'failure' || steps.forward_apply.outcome == 'cancelled')" &&
                active_line?(preserve['run'], 'bash scripts/genie-qa/forward_preservation.sh "$RUNNER_TEMP/qa-preservation-before.json"'),
                'post-apply preservation proof missing')
require_control(env['GENIE_QA_RECOVERY_REFERENCE'] == '$' + '{{ inputs.recovery_reference }}' &&
                env['GENIE_QA_VERIFIED_STATE_SHA256'] == '$' + '{{ inputs.verified_state_sha256 }}',
                'reviewed recovery evidence bindings missing')

# Reject unapproved schema-write steps; only the specified dry-run/apply/forward-apply can invoke db push.
push_steps = steps.select { |step| step.is_a?(Hash) && step['run'].is_a?(String) &&
                           step['run'].include?('supabase db push') }
require_control(push_steps == [dry, apply, forward], 'unexpected schema-write step')
require_control(steps.none? { |step| step.is_a?(Hash) &&
                  (step['env'] || {}).to_s.match?(/SUPABASE_DB_URL|SUPABASE_ACCESS_TOKEN/) },
                'production credentials forbidden')
puts 'GENIE_QA_PROTECTED_WORKFLOW_PASS'
