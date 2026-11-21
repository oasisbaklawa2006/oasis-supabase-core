#!/usr/bin/env ruby
# Fail-closed active-YAML policy for manual, isolated Genie QA MSG91 Edge release.
# This guard never reads credentials, contacts Supabase, or deploys functions.
require 'psych'
require 'digest'

def gate(ok, reason)
  abort("GENIE_QA_MSG91_EDGE_WORKFLOW_DENIED: #{reason}") unless ok
end

begin
  raw = File.read(ARGV.fetch(0))
  # Freeze the entire approved workflow byte-for-byte. A commented-out
  # condition, a reordered check, or a YAML-level bypass changes this hash.
  # Changes require an explicit guard update and fresh independent review.
  workflow_sha256 = '8334f836dc8e870df2ed51b45abfae5dd33aeaf7fb74c816cf7a758c3f3963a2'
  gate(Digest::SHA256.hexdigest(raw) == workflow_sha256, 'approved QA workflow SHA-256 changed')
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
  'QA_MIGRATION_SOURCE_SHA' => 'a4ec8aafc41afa14717c092e583ebb697fe000ef',
  'QA_EDGE_MODE' => '${{ inputs.mode }}',
  'EXPECTED_SHA' => '${{ inputs.expected_head_sha }}',
  'QA_EDGE_CHANGE_REFERENCE' => '${{ inputs.change_reference }}',
  'QA_EDGE_APPROVAL' => '${{ inputs.authorization }}',
  'CLI_VERSION' => '2.117.0'
}
required_vars.each { |key, value| gate(env[key] == value, "QA binding changed: #{key}") }
gate(env.keys.sort == required_vars.keys.sort, "unexpected job-level bindings or secrets")
gate(!raw.include?('tcxvcatsqqertcnycuop'), 'production reference prohibited')

steps = job['steps']
gate(steps.is_a?(Array), 'steps missing')
expected_steps = [
  'Validate protected dispatch provenance before checkout',
  'Checkout exact protected Core main',
  'Validate protected QA Edge workflow and owner intent',
  'Verify source closures and offline MSG91 denial contracts',
  'Verify strict direct QA TLS and commissioned no-egress schema',
  'Set up pinned Supabase CLI',
  'Refuse provider credentials and any pre-existing QA Edge functions',
  'Explicitly approved QA-only MSG91 dual-function deployment'
]
gate(steps.map { |step| step.is_a?(Hash) ? step['name'] : nil } == expected_steps,
     'required security steps reordered, missing or added')
steps.each_with_index do |step, index|
  gate(!step.key?('continue-on-error'), "security step #{index} must fail closed")
  gate(!step.key?('if') || (index == 7 && step['if'] == "inputs.mode == 'deploy'"),
       "security step #{index} cannot be skipped or conditionally bypassed")
  if step.key?('run')
    gate(step['shell'] == 'bash' && step['run'].is_a?(String) &&
         step['run'].lstrip.start_with?('set -euo pipefail'),
         "security step #{index} must use strict bash")
  end
end
def named(steps, name)
  found = steps.select { |s| s.is_a?(Hash) && s['name'] == name }
  gate(found.size == 1, "missing or duplicate step: #{name}")
  found.fetch(0)
end
def has?(step, text)
  # Source-code assertions ignore full-line shell comments. The frozen
  # SHA-256 separately rejects any other altered or unreachable commands.
  step['run'].is_a?(String) && step['run'].lines.any? do |line|
    active_line = line.strip
    !active_line.start_with?('#') && active_line.include?(text)
  end
end
def active?(step, text)
  step['run'].is_a?(String) && step['run'].lines.any? { |line| line.strip == text }
end

precheck = named(steps, 'Validate protected dispatch provenance before checkout')
gate(precheck['env'] == { 'GH_TOKEN' => '${{ github.token }}' }, 'precheckout must only use read-only GitHub credential')
gate(has?(precheck, 'test "$GITHUB_SHA" = "$EXPECTED_SHA"') &&
     has?(precheck, 'test "$current_main" = "$EXPECTED_SHA"') &&
     has?(precheck, "approval_ref_regex='^Core#495/Buyer#64;QA-EDGE-APPROVAL=[A-Za-z0-9._/-]{6,128}$'") &&
     has?(precheck, 'GENIE_QA_PROTECTED_DISPATCH_PRECHECK_PASS'),
     'protected event SHA/current main/approval reference must precede checkout')

checkout = named(steps, 'Checkout exact protected Core main')
gate(checkout['with'].is_a?(Hash) && checkout['with']['ref'] == '${{ github.sha }}' &&
     checkout['with']['persist-credentials'] == false, 'checkout no longer pinned')
scope = named(steps, 'Validate protected QA Edge workflow and owner intent')
gate(active?(scope, 'ruby scripts/genie-qa/verify_msg91_qa_edge_workflow.rb .github/workflows/genie-qa-msg91-edge-commission.yml'), 'active YAML guard missing')
gate(has?(scope, 'test "$GITHUB_SHA" = "$EXPECTED_SHA"') &&
     has?(scope, 'test "$(git rev-parse HEAD)" = "$EXPECTED_SHA"'), 'checked-out event SHA identity missing')
gate(has?(scope, 'test "$QA_EDGE_APPROVAL" = ' + "'AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY'"), 'owner approval phrase absent')
gate(has?(scope, 'test -z "$QA_EDGE_APPROVAL"'), 'preflight must not accept deploy phrase')
gate(!scope.key?('env'), 'scope stage must not receive provider or database credentials')

contracts = named(steps, 'Verify source closures and offline MSG91 denial contracts')
gate(has?(contracts, 'node --test supabase/tests/msg91_legacy_modes_guard.test.mjs') &&
     has?(contracts, 'scripts/edge-function-source-manifest.py supabase/functions msg91-otp') &&
     has?(contracts, 'scripts/edge-function-source-manifest.py supabase/functions msg91-session-bridge'),
     'MSG91 source closure or offline denial contract missing')

db = named(steps, 'Verify strict direct QA TLS and commissioned no-egress schema')
gate(db['env'] == { 'QA_DATABASE_URL' => '${{ secrets.GENIE_QA_DATABASE_URL }}',
                    'QA_CA_CERT_PEM' => '${{ secrets.GENIE_QA_CA_CERT_PEM }}' },
     'QA database secrets must be scoped to the DB attestation step')
gate(has?(db, 'guard.validate_target(os.environ.get("QA_DATABASE_URL", ""), mode="apply")') &&
     active?(db, 'echo "PGSSLMODE=verify-full" >> "$GITHUB_ENV"') &&
     has?(db, "test \"$state\" = '516|1|0|1|1|1|0|0|true|false|false'") &&
     has?(db, "(SELECT count(*)::int FROM auth.sessions)") &&
     has?(db, "(SELECT count(*)::int FROM auth.refresh_tokens)") &&
     has?(db, "'c1000000-0000-4000-8000-000000000001'::uuid") &&
     has?(db, 'git ls-tree -r --name-only "$QA_MIGRATION_SOURCE_SHA"') &&
     has?(db, 'GENIE_QA_EDGE_MIGRATION_VERSION_SET_DRIFT') &&
     has?(db, 'cmp -s "$RUNNER_TEMP/qa-expected-versions.txt"'),
     'QA direct TLS / canonical identity / 516-version ledger integrity changed')

secrets = named(steps, 'Refuse provider credentials and any pre-existing QA Edge functions')
gate(secrets['env'] == { 'SUPABASE_ACCESS_TOKEN' => '${{ secrets.SUPABASE_ACCESS_TOKEN }}' },
     'Management API token must be scoped to secret inventory step')
gate(has?(secrets, 'https://api.supabase.com/v1/projects/$QA_PROJECT_REF/secrets') &&
     has?(secrets, 'python3 scripts/genie-qa/verify_msg91_secret_inventory.py') &&
     has?(secrets, 'GENIE_QA_EDGE_SECRET_NAMES_UNPARSABLE') &&
     has?(secrets, 'GENIE_QA_EDGE_SECRET_NAMES_UNPARSABLE_OR_PROVIDER_KEY_PRESENT') &&
     has?(secrets, 'GENIE_QA_EDGE_ALREADY_EXISTS_STOP_FOR_RECONCILIATION') &&
     has?(secrets, "jq -e 'type == \"array\" and length == 0'"),
     'provider-denial or existing-function check missing')

deploy = named(steps, 'Explicitly approved QA-only MSG91 dual-function deployment')
gate(deploy['env'] == { 'SUPABASE_ACCESS_TOKEN' => '${{ secrets.SUPABASE_ACCESS_TOKEN }}' },
     'Management API token must be scoped to deployment step')
gate(deploy['if'] == "inputs.mode == 'deploy'", 'deployment allowed without approved mode')
gate(active?(deploy, "test \"$QA_EDGE_APPROVAL\" = 'AUTHORIZE-GENIE-QA-MSG91-EDGE-DEPLOY'"), 'deploy write authorization missing')
gate(has?(deploy, 'supabase functions deploy msg91-otp') &&
     has?(deploy, 'supabase functions deploy msg91-session-bridge') &&
     deploy['run'].scan('--project-ref "$QA_PROJECT_REF" --no-verify-jwt').size == 2,
     'deploy target/function or public widget mode changed')
gate(has?(deploy, 'workdir="$RUNNER_TEMP/genie-qa-msg91-deploy"') &&
     has?(deploy, 'cp -a supabase/functions/msg91-otp') &&
     has?(deploy, 'cp -a supabase/functions/msg91-session-bridge') &&
     has?(deploy, 'cp -a supabase/functions/_shared') &&
     has?(deploy, %q{printf 'project_id = "skhpmltfjgqitntkmclb"}) &&
     active?(deploy, 'cd "$workdir"'),
     'ephemeral QA-only function source/config workspace required')
gate(has?(deploy, 'GENIE_QA_BRIDGE_DEPLOY_FAILED_PARTIAL_STATE_STOP') &&
     has?(deploy, 'GENIE_QA_EDGE_PARITY_FAILED_STOP') &&
     has?(deploy, 'cp scripts/genie-qa/inert_msg91_provider_verify.mjs') &&
     has?(deploy, 'cmp -s scripts/genie-qa/inert_msg91_provider_verify.mjs') &&
     has?(deploy, 'GENIE_QA_EDGE_JWT_AUTHORITY_UNVERIFIED') &&
     has?(deploy, 'GENIE_QA_EDGE_PROVIDER_SECRET_ADDED') &&
     has?(deploy, 'qa-expected-source-$slug.json') &&
     has?(deploy, 'supabase functions download "$slug"') &&
     has?(deploy, 'GENIE_QA_EDGE_DEPLOYED_SOURCE_MISMATCH') &&
     has?(deploy, 'remote="$(mktemp -d "$RUNNER_TEMP/qa-remote-attest-$slug.XXXXXXXX")"') &&
     has?(deploy, 'GENIE_QA_EDGE_REMOTE_ATTEST_TMP_FAILED') &&
     has?(deploy, 'verify_msg91_bundle_provenance.py') &&
     has?(deploy, 'GENIE_QA_EDGE_ATTESTED_BUNDLE_CHANGED') &&
     has?(deploy, 'GENIE_QA_EDGE_LAST_BUNDLE_CHANGED') &&
     deploy['run'].scan('--mode capture').size == 1 &&
     deploy['run'].scan('--mode final').size == 2 &&
     deploy['run'].scan('attest_deployed_source msg91-otp').size == 2 &&
     deploy['run'].scan('attest_deployed_source msg91-session-bridge').size == 1,
     'QA-only inert provider overlay, downloaded source proof or partial-deploy stop missing')

writes = steps.select { |s| s.is_a?(Hash) && s['run'].is_a?(String) && s['run'].include?('supabase functions deploy') }
gate(writes == [deploy], 'additional write step outside protected deploy')
gate(steps.none? { |s| s.is_a?(Hash) && s['run'].is_a?(String) &&
                    s['run'].match?(/supabase\s+(?:db\s+push|migration\s+up|secrets\s+set)/) },
     'schema and secrets mutations not allowed in QA Edge release')
puts 'GENIE_QA_MSG91_EDGE_WORKFLOW_PASS'
