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
                mode['options'] == %w[preflight apply] && mode['default'] == 'preflight',
                'preflight/apply input contract changed')
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
env = job['env']
require_control(env.is_a?(Hash), 'QA environment binding required')
require_control(env['GENIE_QA_PROJECT_REF'] == 'skhpmltfjgqitntkmclb', 'QA project changed')
require_control(env['GENIE_QA_RUN_MODE'] == '$' + '{{ inputs.mode }}', 'run mode changed')
require_control(env['GENIE_QA_EXPECTED_SHA'] == '$' + '{{ inputs.expected_head_sha }}', 'head SHA binding changed')
require_control(env['GENIE_QA_DATABASE_URL'] == '$' + '{{ secrets.GENIE_QA_DATABASE_URL }}', 'QA DB secret changed')
require_control(env['GENIE_QA_CA_CERT_PEM'] == '$' + '{{ secrets.GENIE_QA_CA_CERT_PEM }}', 'QA root CA secret changed')
require_control(env['GENIE_QA_APPROVAL_PHRASE'] == '$' + '{{ inputs.authorization }}', 'apply approval input changed')

steps = job['steps']
require_control(steps.is_a?(Array), 'workflow steps required')
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

# Reject unapproved schema-write steps; only the specified dry-run/apply can invoke db push.
push_steps = steps.select { |step| step.is_a?(Hash) && step['run'].is_a?(String) &&
                           step['run'].include?('supabase db push') }
require_control(push_steps == [dry, apply], 'unexpected schema-write step')
require_control(steps.none? { |step| step.is_a?(Hash) &&
                  (step['env'] || {}).to_s.match?(/SUPABASE_DB_URL|SUPABASE_ACCESS_TOKEN/) },
                'production credentials forbidden')
puts 'GENIE_QA_PROTECTED_WORKFLOW_PASS'
