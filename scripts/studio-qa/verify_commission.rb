#!/usr/bin/env ruby
# Fail-closed source contract for the read-only Studio QA commissioning lane.
# This validator intentionally refuses to recognize a deploy-capable workflow.
require "yaml"

path = ARGV.fetch(0, ".github/workflows/studio-ai-copy-qa-commission.yml")
def deny(reason)
  abort("STUDIO_QA_COMMISSION_CONTRACT_DENIED: #{reason}")
end
def require_gate(assertion, reason)
  deny(reason) unless assertion
end

data = YAML.safe_load(File.read(path), aliases: false)
require_gate(data.is_a?(Hash), "workflow mapping")
trigger = data.fetch("on", data[true])
require_gate(trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"], "manual-only event")
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
require_gate(inputs.keys.sort == %w[change_reference expected_head_sha mode preflight_run_id],
             "exact dispatch inputs")
require_gate(inputs.values.all? { |v| v["required"] == true }, "mandatory dispatch inputs")
require_gate(inputs.fetch("mode").fetch("options") == %w[readiness deploy cleanup],
             "readiness-mode choices")
require_gate(inputs.fetch("mode").fetch("default") == "readiness", "default must be inert")
require_gate(data.fetch("permissions") == {"contents" => "read", "actions" => "read"},
             "GitHub permission amplification")
require_gate(data.fetch("concurrency").fetch("cancel-in-progress") == false, "cancellable audit")
require_gate(data.fetch("jobs").keys == ["qa-readiness"], "unexpected job")
job = data.fetch("jobs").fetch("qa-readiness")
require_gate(job.fetch("environment") == "genie-qa-bootstrap", "unprotected QA environment")
require_gate(job.fetch("runs-on") == "ubuntu-24.04", "runner drift")
require_gate(job.fetch("if") == "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'",
             "not exact Core main")
require_gate(job.fetch("env") == {
  "QA_PROJECT_REF" => "skhpmltfjgqitntkmclb",
  "EXPECTED_SHA" => '${{ inputs.expected_head_sha }}',
  "PREFLIGHT_RUN_ID" => '${{ inputs.preflight_run_id }}',
  "CHANGE_REFERENCE" => '${{ inputs.change_reference }}',
  "RELEASE_MODE" => '${{ inputs.mode }}',
  "GH_TOKEN" => '${{ github.token }}'
}, "unexpected global credential or target")

names = [
  "Bind dispatch to exact current protected main",
  "Checkout immutable protected Core source",
  "Verify commissioning safety contract and exact inert closure",
  "Verify successful protected preflight provenance on same SHA",
  "Check current QA provider secrets and Edge-zero state read-only",
  "Block deployment and cleanup until external-writer control is proven"
]
steps = job.fetch("steps")
require_gate(steps.map { |s| s.fetch("name") } == names, "missing, extra or reordered step")
require_gate(steps.none? { |s| s.key?("if") || s["continue-on-error"] || s.key?("working-directory") },
             "skippable/failing/alternate-path step")
checkout = steps[1]
require_gate(checkout.fetch("uses") == "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd",
             "checkout not SHA-pinned")
require_gate(checkout.fetch("with") == {"ref" => '${{ github.sha }}', "persist-credentials" => false},
             "mutable checkout or credential persistence")

steps.each_with_index do |step, i|
  next if i == 1
  require_gate(step.fetch("shell") == "bash", "shell drift")
  body = step.fetch("run")
  require_gate(body.start_with?("set -euo pipefail\n"), "non-failing shell")
  require_gate(!body.match?(/\bsupabase\s+(?:functions\s+(?:deploy|delete)|secrets\s+set|db\s+(?:push|reset)|migration\s+up)\b/i),
               "deploy or database mutation")
  require_gate(!body.match?(/\bcurl\s+[^\n]*(?:-X\s+(?:POST|PUT|PATCH|DELETE)|--request\s+(?:POST|PUT|PATCH|DELETE))/i),
               "HTTP mutation")
  require_gate(!body.match?(/\b(?:psql|pg_restore|pg_dump)\b/), "unreviewed database access")
end

require_gate(steps[0].fetch("run").include?('test "$GITHUB_SHA" = "$EXPECTED_SHA"') &&
             steps[0].fetch("run").include?('commits/main'), "current main pin")
source = steps[2].fetch("run")
%w[verify_commission.rb test_studio_qa_commission.rb build_inert_copy.py
   test_studio_qa_ai_copy.py test_studio_qa_bundle.py edge-function-source-manifest.py].each do |token|
  require_gate(source.include?(token), "inert source proof missing")
end
require_gate(source.include?("verify_jwt = true") && source.include?('fileCount == 2'),
             "JWT or source closure contract weakened")
provenance = steps[3].fetch("run")
%w[studio-ai-copy-qa-preflight.yml workflow_dispatch conclusion workflow_id head_sha head_branch].each do |token|
  require_gate(provenance.include?(token), "protected preflight provenance missing")
end
require_gate(provenance.include?("Check QA-only provider-secret absence and zero deployed functions") &&
             provenance.include?("Assert no QA or Production mutations and report next protected gate"),
             "preflight pass steps not bound")
inventory = steps[4]
require_gate(inventory.fetch("env") == {
  "SUPABASE_ACCESS_TOKEN" => '${{ secrets.SUPABASE_ACCESS_TOKEN }}'
}, "read-only credential must be isolated")
require_gate((steps[0...4] + [steps[5]]).all? { |s| !s.key?("env") },
             "other secret-bearing steps forbidden")
require_gate(inventory.fetch("run").include?("verify_secrets.py") &&
             inventory.fetch("run").include?('length == 0') &&
             inventory.fetch("run").include?("api.supabase.com/v1/projects/$QA_PROJECT_REF/functions"),
             "provider or Edge-zero inventory missing")
blocked = steps[5].fetch("run")
require_gate(blocked.include?('if [[ "$RELEASE_MODE" != readiness ]]; then') &&
             blocked.include?("STUDIO_QA_EXTERNAL_WRITER_CONTROL_UNVERIFIED") &&
             blocked.include?("exit 1") &&
             blocked.include?("commits/main"),
             "external-writer block removed")
require_gate(!File.read(path).include?('secrets.STUDIO_QA_DEPLOY_TOKEN'),
             "write token referenced by read-only workflow")
puts "STUDIO_QA_COMMISSION_CONTRACT_PASS"
