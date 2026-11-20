#!/usr/bin/env ruby
# Fail-closed active-YAML policy for manual, isolated Genie QA MSG91 Edge release.
# This guard never reads credentials, contacts Supabase, or deploys functions.
require 'psych'

def gate(ok, reason)
  abort("GENIE_QA_MSG91_EDGE_WORKFLOW_DENIED: #{reason}") unless ok
end

begin
  raw = File.read(ARGV.fetch(0))
  wf = Psych.safe_load(raw, aliases: false)
rescue StandardError
  abort('GENIE_QA_MSG91_EDGE_WORKFLOW_DENIED: invalid or unreadable YAML')
end

gate(wf.is_a?(Hash), 'workflow mapping missing')
events = wf['on'] || wf[true]
gate(events.is_a?(Hash) && events.keys == ['workflow_dispatch'], 'automatic triggers not permitted')
inputs = events.dig('workflow_dispatch', 'inputs')
gate(inputs.is_a?(Hash), 'dispatch input schema missing')
gate(inputs['expected_head_sha'].is_a?(Hash) && inputs['expected_head_sha']['required'] == true, 'exact SHA input missing')
gate(inputs['change_reference'].is_a?(Hash) && inputs['change_reference']['required'] == true, 'change reference input missing')
gate(inputs['authorization'].is_a?(Hash), 'explicit authorization input missing')
mode = inputs['mode']
gate(mode.is_a?(Hash) && mode['type'] == 'choice' && mode['options'] == %w[preflight deploy] && mode['default'] == 'preflight', 'preflight default changed')
gate(wf['permissions'] == { 'contents' => 'read' }, 'workflow GitHub permissions broadened')
gate(wf['concurrency'].is_a?(Hash) && wf['concurrency']['cancel-in-progress'] == false, 'concurrency can auto-cancel partial deploy')
jobs = wf['jobs']
gate(jobs.is_a?(Hash) && jobs.keys == ['qa-edge'], 'unexpected jobs')
job = jobs['qa-edge']
gate(job.is_a?(Hash), 'QA job missing')
expected_if = "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'"
gate(job['if'] == expected_if, 'protected main source restriction removed')
gate(job['environment'] == 'genie-qa-bootstrap', 'protected QA environment missing')
gate(job['runs-on'] == 'ubuntu-24.04', 'runner changed')
env = job['env']
gate(env.is_a?(Hash), 'QA variables missing')
required_vars = {
  'QA_PROJECT_REF' => 'skhpmltfjgqitntkmclb',
  'QA_EDGE_MODE' => '${{ inputs.mode }}',
  'EXPECTED_SHA' => '${{ inputs.expected_head_sha }}',
  'QA_EDGE_CHANGE_REFERENCE' => '${{ inputs.change_reference }}',
  'QA_EDGE_APPROVAL' => '${{ inputs.authorization }}',
  'QA_DATABASE_URL' => '${{ secrets.GENIE_QA_DATABASE_URL }}',
  'QA_CA_CERT_PEM' => '${{ secrets.GENIE_QA_CA_CERT_PEM }}',
  'SUPABASE_ACCESS_TOKEN' => '${{ secrets.SUPABASE_ACCESS_TOKEN }}'
}
required_vars.each { |key, value| gate(env[key] == value, "QA binding changed: #{key}") }
gate(!raw.include?('tcxvcatsqqertcnycuop'), 'production reference prohibited')

steps = job['steps']
gate(steps.is_a?(Array), 'steps missing')
def named(steps, name)
  found = steps.select { |s| s.is_a?(Hash) && s['name'] == name }
  gate(found.size == 1, "missing or duplicate step: #{name}")
  found.fetch(0)
end
def has?(step, text)
  step['run'].is_a?(String) && step['run'].include?(text)
end
def active?(step, text)
  step['run'].is_a?(String) && step['run'].lines.any? { |line| line.strip == text }
end

checkout = named(steps, 'Checkout exact protected Core main')
gate(checkout['with'].is_a?(Hash) && checkout['with']['ref'] == '${{ inputs.expected_head_sha }}' &&
     checkout['with']['persist-credentials'] == false, 'checkout no longer pinned')
scope = named(steps, 'Validate protected QA Edge workflow and owner intent')
gate(active?(scope, 'ruby scripts/genie-qa/verify_msg91_qa_edge_workflow.rb .github/workflows/genie-qa-msg91-edge-commission.yml'), 'active YAML guard missing')
gate(has?(scope, 'test "$GITHUB_SHA" = "$EXPECTED_SHA"') &&
     has?(scope, 'test "$current_main" = "$EXPECTED_SHA"') &&
     has?(scope, 'test "$GITHUB_REF" ='), 'exact current protected main proof missing')
gate(has?(scope, 'test "$QA_EDGE_APPROVAL" = ' + "'AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY'"), 'owner approval phrase absent')
gate(has?(scope, 'test -z "$QA_EDGE_APPROVAL"'), 'preflight must not accept deploy phrase')
gate(has?(scope, 'test -n "$SUPABASE_ACCESS_TOKEN"'), 'token presence check missing')

contracts = named(steps, 'Verify source closures and offline MSG91 denial contracts')
gate(has?(contracts, 'node --test supabase/tests/msg91_legacy_modes_guard.test.mjs') &&
     has?(contracts, 'scripts/edge-function-source-manifest.py supabase/functions msg91-otp') &&
     has?(contracts, 'scripts/edge-function-source-manifest.py supabase/functions msg91-session-bridge'),
     'MSG91 source closure or offline denial contract missing')

db = named(steps, 'Verify strict direct QA TLS and commissioned no-egress schema')
gate(has?(db, 'guard.validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="apply")') &&
     active?(db, 'echo "PGSSLMODE=verify-full" >> "$GITHUB_ENV"') &&
     has?(db, "test \"$state\" = '516|1|0|1|true|false|false'"),
     'QA direct TLS / 516-ledger / no-egress and identity gates changed')

secrets = named(steps, 'Refuse provider credentials and any pre-existing QA Edge functions')
gate(has?(secrets, 'supabase secrets list --project-ref "$QA_PROJECT_REF"') &&
     has?(secrets, "grep -Fxq 'MSG91_AUTH_KEY'") &&
     has?(secrets, 'GENIE_QA_EDGE_PROVIDER_KEY_PRESENT_BLOCKS_INERT_DEPLOY') &&
     has?(secrets, 'GENIE_QA_EDGE_ALREADY_EXISTS_STOP_FOR_RECONCILIATION') &&
     has?(secrets, "jq -e 'type == \"array\" and length == 0'"),
     'provider-denial or existing-function check missing')

deploy = named(steps, 'Explicitly approved QA-only MSG91 dual-function deployment')
gate(deploy['if'] == "inputs.mode == 'deploy'", 'deployment allowed without approved mode')
gate(active?(deploy, "test \"$QA_EDGE_APPROVAL\" = 'AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY'"), 'deploy write authorization missing')
gate(has?(deploy, 'supabase functions deploy msg91-otp') &&
     has?(deploy, 'supabase functions deploy msg91-session-bridge') &&
     deploy['run'].scan('--project-ref "$QA_PROJECT_REF" --no-verify-jwt').size == 2,
     'deploy target/function or public widget mode changed')
gate(has?(deploy, 'GENIE_QA_BRIDGE_DEPLOY_FAILED_PARTIAL_STATE_STOP') &&
     has?(deploy, 'GENIE_QA_EDGE_PARITY_FAILED_STOP'), 'partial-deploy stop missing')

writes = steps.select { |s| s.is_a?(Hash) && s['run'].is_a?(String) && s['run'].include?('supabase functions deploy') }
gate(writes == [deploy], 'additional write step outside protected deploy')
gate(steps.none? { |s| s.is_a?(Hash) && s['run'].is_a?(String) &&
                    s['run'].match?(/supabase\s+(?:db\s+push|migration\s+up|secrets\s+set)/) },
     'schema and secrets mutations not allowed in QA Edge release')
puts 'GENIE_QA_MSG91_EDGE_WORKFLOW_PASS'
