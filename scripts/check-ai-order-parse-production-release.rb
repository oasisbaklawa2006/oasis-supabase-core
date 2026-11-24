#!/usr/bin/env ruby
# Fail-closed credential-free policy for the protected Buyer Genie ai-order-parse release.
require "yaml"

canonical_path = ".github/workflows/buyer-genie-ai-order-parse-production-release.yml"
workflow_path = ARGV.fetch(0, canonical_path)
data = YAML.safe_load(File.read(workflow_path), aliases: false)
def gate(condition, message)
  abort("AI-ORDER-PARSE RELEASE GOVERNANCE: #{message}") unless condition
end

gate(data.is_a?(Hash), "missing YAML object")
trigger = data.fetch("on", data[true])
gate(trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"], "manual dispatch only")
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
required = %w[
  release_sha deploy preview_uat_approved rollback_approved
  approved_preflight_run_id approved_preflight_artifact_id approved_rollback_sha256
]
gate(inputs.keys.sort == required.sort, "unexpected or missing release input")
%w[deploy preview_uat_approved rollback_approved].each do |key|
  gate(inputs.fetch(key).fetch("default") == false, "unsafe #{key} default")
end
%w[approved_preflight_run_id approved_preflight_artifact_id approved_rollback_sha256].each do |key|
  gate(inputs.fetch(key).fetch("default") == "", "unsafe #{key} input default")
end
gate(data.fetch("permissions") == {"contents" => "read", "actions" => "read"}, "write-capable workflow permissions")
gate(data.fetch("concurrency").fetch("cancel-in-progress") == false, "unsafe concurrency cancellation")
gate(!data["continue-on-error"], "workflow-level continue-on-error")
env = data.fetch("env")
gate(env.fetch("PROJECT_REF") == "tcxvcatsqqertcnycuop", "wrong Production project")
gate(env.fetch("FUNCTION_NAME") == "ai-order-parse", "function scope changed")
gate(env.fetch("EXPECTED_LIVE_VERSION").to_s == "5", "live version not pinned")
gate(
  env.fetch("EXPECTED_LIVE_BUNDLE_SHA") == "4f4c48f94f787cd0fec068a3376fece455449b4dbb9ae427dda97aeade0e0004",
  "live bundle SHA not pinned"
)

jobs = data.fetch("jobs")
gate(jobs.keys.sort == %w[contract deploy preflight], "unexpected or missing release job")
expected_conditions = {
  "contract" => nil,
  "preflight" => nil,
  "deploy" => [
    "github.event_name == 'workflow_dispatch'",
    "inputs.deploy == true",
    "inputs.preview_uat_approved == true",
    "inputs.rollback_approved == true",
  ].join(" && "),
}
jobs.each do |name, job|
  gate(!job["continue-on-error"], "nonfatal job #{name}")
  condition = job["if"]&.gsub(/\s+/, " ")&.strip
  gate(condition == expected_conditions.fetch(name), "unsafe job predicate #{name}")
  gate(job.fetch("runs-on") == "ubuntu-24.04", "unexpected runner for #{name}")
  job.fetch("steps").each do |step|
    if step.key?("if")
      gate(
        step.fetch("if") == "always()" && step["name"] == "Archive sanitized post-release deployment evidence",
        "conditional or suppressed mandatory step #{name}/#{step['name']}"
      )
    end
    gate(!step["continue-on-error"], "nonfatal step #{name}/#{step['name']}")
    gate(!step["shell"] || step["shell"] == "bash", "unsafe shell #{name}/#{step['name']}")
  end
end
gate(jobs.fetch("preflight").fetch("environment") == "supabase-production-readonly", "preflight must be read-only")
gate(jobs.fetch("deploy").fetch("environment") == "supabase-production", "missing independently protected Production deployment")
gate(!jobs.fetch("contract").key?("environment"), "contract job must be credential-free")

contract = jobs.fetch("contract").fetch("steps")
gate(contract.first.fetch("name") == "Reject non-main dispatch before checking out or executing candidate code", "missing pre-checkout ref guard")
gate(contract.first.fetch("run").include?('test "$GITHUB_REF" = refs/heads/main'), "unprotected contract ref")
gate(contract.first.fetch("run").include?('test "$GITHUB_SHA" = "$RELEASE_SHA"'), "unbound contract SHA")
preflight = jobs.fetch("preflight").fetch("steps")
source_capture = preflight.find { |x| x["name"] == "Capture complete restorable live source and reviewed candidate closure" }
gate(!source_capture.nil?, "missing rollback capture")
capture = source_capture.fetch("run")
gate(capture.match?(/>\s*live-after-download\.json/) &&
  capture.match?(/jq -e[\s\S]*live-after-download\.json\s*>\s*\/dev\/null/) &&
  capture.include?("verify_jwt == true") &&
  capture.index("live-after-download.json") < capture.index("capture-live-edge-function-rollback-artifacts.sh"),
  "source was not re-bound to v5 after download")
summary = preflight.find { |x| x["name"] == "Publish the immutable archive identity for a separate owner review" }
gate(!summary.nil? && summary.fetch("run").include?("GITHUB_STEP_SUMMARY"), "preflight artifact ID and SHA not reviewable")
secret_guard = preflight.find { |x| x["name"] == "Require the Production Gemini secret by NAME only; never read or print values" }
gate(!secret_guard.nil? &&
  secret_guard.fetch("run").include?('.name == "GEMINI_API_KEY"') &&
  secret_guard.fetch("run").include?("AI_ORDER_PARSE_GEMINI_API_KEY_SECRET_ABSENT"),
  "preflight lacks the Gemini secret-presence gate")

deploy_steps = jobs.fetch("deploy").fetch("steps")
approved = deploy_steps.find { |x| x["name"] == "Bind reviewed prior successful preflight run and exact rollback artifact" }
gate(!approved.nil? && approved.fetch("run").include?("prior-artifact.json") &&
  approved.fetch("run").include?(".workflow_run.id == $run") &&
  approved.fetch("run").include?('.head_sha == $sha'), "rollback not bound to reviewed prior GitHub run and artifact")
download = deploy_steps.find { |x| x["name"] == "Download exactly the independently reviewed prior rollback archive" }
gate(!download.nil? && download.fetch("with").fetch("run-id") == "${{ inputs.approved_preflight_run_id }}" &&
  download.fetch("with").fetch("artifact-ids") == "${{ inputs.approved_preflight_artifact_id }}",
  "rollback download not bound to reviewed immutable ID")
baseline = deploy_steps.find { |x| x["name"] == "Verify rollback, exact current main and the unchanged v5 baseline" }
gate(!baseline.nil? &&
  baseline.fetch("run").lines.map(&:strip).include?(%q{test "$(sha256sum preflight/live-v5-rollback.tar.gz | awk '{print $1}')" = "$APPROVED_ROLLBACK_SHA256"}) &&
  baseline.fetch("run").include?("cmp preflight/live-v5-manifest.json current-preflight/live-v5-manifest.json"),
  "approved rollback digest/current live manifest not checked")
deploy_step = deploy_steps.find { |x| x["name"] == "Deploy ai-order-parse ONLY; preserve JWT and existing secrets" }
gate(!deploy_step.nil?, "missing named-function write step")
deploy_code = deploy_step.fetch("run")
gate(deploy_code.include?('.name == "GEMINI_API_KEY"') &&
  deploy_code.index('.name == "GEMINI_API_KEY"') < deploy_code.index("supabase functions deploy"),
  "secret-presence check not immediately before write")
post = deploy_steps.find { |x| x["name"] == "Verify version, JWT and every deployed closure file" }
gate(!post.nil? &&
  post.fetch("run").include?('git rev-parse refs/remotes/origin/main') &&
  post.fetch("run").include?("candidate-final.json") &&
  post.fetch("run").include?('cmp "supabase/functions/$rel" "deployed-source/supabase/functions/$rel"'),
  "postwrite SHA or closure parity check missing")

all_commands = jobs.values.flat_map { |job| job.fetch("steps") }.map { |step| step.fetch("run", "") }.join("\n")
gate(!all_commands.match?(/supabase\s+(secrets\s+(?:set|unset)|db\s+push|migration\s+(?:up|repair))/),
  "secret mutation/schema write in release")
gate(!all_commands.include?("--no-verify-jwt"), "JWT security weakened")
gate(!all_commands.include?("|| true"), "release check made optional")
gate(all_commands.include?("edge-function-source-manifest.py"), "missing canonical closure proof")
gate(all_commands.include?("verify_jwt == true"), "JWT posture not checked")
# CLI 2.117 accepts multiple positional names. Pin the exact FULL command.
deploy_commands = all_commands.lines.map(&:strip).select { |line| line.match?(/\bsupabase\s+functions\s+deploy\b/) }
exact = 'supabase functions deploy ai-order-parse --project-ref "$PROJECT_REF" --use-api'
gate(deploy_commands == [exact], "one named function only, exact safe flags")
puts "Buyer Genie ai-order-parse protected named-function release contract passed."
