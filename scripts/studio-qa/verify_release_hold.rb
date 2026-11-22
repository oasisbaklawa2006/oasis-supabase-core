#!/usr/bin/env ruby
# Studio QA-only executable workflow contract. Owner accepted shared-writer
# risk for isolated skhpmltfjgqitntkmclb on 23 Nov 2026; no Production scope.
require "yaml"

path = ARGV.fetch(0, ".github/workflows/studio-ai-copy-qa-release.yml")
def gate(condition, message)
  abort("STUDIO_QA_RELEASE_CONTRACT_DENIED: #{message}") unless condition
end

data = YAML.safe_load(File.read(path), aliases: false)
gate(data.is_a?(Hash), "workflow YAML missing")
trigger = data.fetch("on", data[true])
gate(trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"], "must be manual-only")
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
gate(inputs.keys.sort == %w[expected_head_sha operation], "unexpected dispatch inputs")
gate(inputs.values.all? { |v| v["required"] == true }, "optional inputs")
gate(inputs.fetch("operation").fetch("options") == %w[deploy rollback], "operation choices")
gate(inputs.fetch("operation").fetch("default") == "deploy", "default not deploy")
gate(data.fetch("permissions") == {"contents" => "read"}, "GitHub write permissions")
gate(data.fetch("concurrency").fetch("cancel-in-progress") == false, "cancellable release")

jobs = data.fetch("jobs")
gate(jobs.keys == ["qa-release"], "unexpected jobs")
job = jobs.fetch("qa-release")
gate(job.fetch("if") == "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'", "not pinned to main")
gate(job.fetch("runs-on") == "ubuntu-24.04", "runner changed")
gate(job.fetch("environment") == "genie-qa-bootstrap", "QA protected environment missing")
gate(job.fetch("env") == {
  "QA_PROJECT_REF" => "skhpmltfjgqitntkmclb",
  "QA_FUNCTION_NAME" => "catalogue-ai-copy",
  "EXPECTED_SHA" => "${{ inputs.expected_head_sha }}",
  "RELEASE_OPERATION" => "${{ inputs.operation }}",
  "GH_TOKEN" => "${{ github.token }}"
}, "job target/credential changed")

steps = job.fetch("steps")
names = [
  "Verify reviewed protected Core main and exact operation",
  "Check out exact reviewed Core main",
  "Verify release policy and provider-inert QA source",
  "Install pinned Supabase CLI for named-function API deploy/delete",
  "Deploy or delete ONLY the QA catalogue-ai-copy function"
]
gate(steps.map { |s| s.fetch("name") } == names, "missing/extra/reordered release step")
gate(steps.none? { |s| s["continue-on-error"] || s.key?("if") }, "skippable/nonfatal step")
gate([0, 2, 4].all? { |i| steps[i].fetch("run").start_with?("set -euo pipefail\n") },
     "strict shell failure handling removed")
gate(steps[0].fetch("run").include?('test "$GITHUB_SHA" = "$EXPECTED_SHA"') &&
     steps[0].fetch("run").include?("commits/main"), "current main verification missing")
gate(steps[1].fetch("uses") == "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd" &&
     steps[1].fetch("with") == {"ref" => "${{ github.sha }}", "persist-credentials" => false},
     "checkout changed")
source = steps[2].fetch("run")
%w[verify_release_hold.rb test_studio_qa_release_hold.rb build_inert_copy.py
   test_studio_qa_ai_copy.py test_studio_qa_bundle.py verify_jwt
   edge-function-source-manifest.py].each do |item|
  gate(source.include?(item), "missing source test: #{item}")
end
gate(source.include?("verify_jwt = true") && source.include?('fileCount == 2'),
     "JWT/source closure weakened")
gate(steps[3].fetch("uses") == "supabase/setup-cli@46f7f98c7f948ad727d22c1e67fab04c223a0520" &&
     steps[3].fetch("with") == {"version" => "2.117.0"}, "CLI not SHA/version pinned")
release = steps[4]
gate(release.fetch("shell") == "bash", "shell changed")
gate(release.fetch("env") == {
  "SUPABASE_ACCESS_TOKEN" => "${{ secrets.STUDIO_QA_DEPLOY_TOKEN }}",
  "SUPABASE_YES" => "true"
}, "write token step changed")
gate(steps[0...4].all? { |s| !s.key?("env") }, "credential exposed before release step")
body = release.fetch("run")
gate(body.start_with?("set -euo pipefail\n"), "release not fail-closed")
%w[skhpmltfjgqitntkmclb catalogue-ai-copy build_inert_copy.py].each do |item|
  # builder is in the earlier source test step
  next if item == "build_inert_copy.py"
  gate(body.include?(item), "QA target changed")
end
gate(body.include?('test "$QA_PROJECT_REF" = skhpmltfjgqitntkmclb') &&
     body.include?('test "$QA_FUNCTION_NAME" = catalogue-ai-copy') &&
     body.include?('test "$GITHUB_SHA" = "$EXPECTED_SHA"') &&
     body.include?("commits/main"), "target or source pin removed")
gate(body.include?('if [[ "$RELEASE_OPERATION" == deploy ]]; then') &&
     body.include?('elif [[ "$RELEASE_OPERATION" == rollback ]]; then'), "both operations required")
gate(body.include?("AI_STUDIO_AI_ENABLED=false") &&
     body.include?("secrets set") &&
     body.include?("secrets unset"), "QA disabled flag and restore missing")
# Bind every write command's own argument line to the approved QA ref.
# Matching a project argument elsewhere (e.g. download) is insufficient.
command_lines = body.lines.map(&:strip)
deploy_start = 'supabase --workdir "$release_dir" functions deploy "$QA_FUNCTION_NAME" ' + 92.chr
delete_start = 'supabase functions delete "$QA_FUNCTION_NAME" ' + 92.chr
deploy_idx = command_lines.index(deploy_start)
delete_idx = command_lines.index(delete_start)
gate(deploy_idx && command_lines[deploy_idx + 1] == '--project-ref "$QA_PROJECT_REF" --use-api --yes',
     "named deploy must target only QA")
gate(delete_idx && command_lines[delete_idx + 1] == '--project-ref "$QA_PROJECT_REF" --yes',
     "named rollback must target only QA")
gate(body.include?("verify_qa_bundle.py") &&
     body.include?("studio-qa-deployed-before.json") &&
     body.include?("studio-qa-deployed-after.json") &&
     body.include?("verify_jwt == true") &&
     body.include?("STUDIO_QA_INERT_FUNCTION_DEPLOYED_AND_ATTESTED"), "remote source/JWT attestation missing")
gate(body.include?("STUDIO_QA_FUNCTION_DELETED_AND_SECRETS_RESTORED") &&
     body.include?('length == 0') &&
     body.include?("verify_secrets.py") &&
     body.include?('length == 0 or (length == 1 and .[0].slug == "catalogue-ai-copy")') &&
     body.include?('if jq -e \'length == 1\' "$before" >/dev/null; then') &&
     body.include?('any(.[]; .name == "AI_STUDIO_AI_ENABLED")'),
     "rollback must tolerate interrupted deletion and secret cleanup")
gate(body.include?('length == 0') && body.include?('length == 1') &&
     body.include?("curl --fail --silent --show-error"), "authoritative QA inventory missing")
gate(!body.match?(/\b(?:db\s+(?:push|reset)|migration\s+(?:up|repair))\b/),
     "database migrations forbidden")
gate(!body.match?(/(?:\A|[[:space:]])--(?:no-verify-jwt|prune)(?=[[:space:]]|\z)/),
     "JWT bypass or pruning flags forbidden")
gate(!data.to_s.include?("secrets.PRODUCTION"), "Production token referenced")
puts "STUDIO_QA_RELEASE_EXECUTABLE_CONTRACT_PASS"
