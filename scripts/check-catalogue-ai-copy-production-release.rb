#!/usr/bin/env ruby
# Credential-free regression: deployment release controls are fail-closed.
require "yaml"

canonical = ".github/workflows/catalogue-ai-copy-production-release.yml"
workflow_path = ARGV.fetch(0, canonical)
data = YAML.safe_load(File.read(workflow_path), aliases: false)
abort "Missing release workflow" unless data.is_a?(Hash)
trigger = data.fetch("on", data[true])
abort "Manual dispatch only" unless trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"]
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
required_inputs = %w[release_sha deploy preview_uat_approved ai_disabled_verified rollback_approved]
required_inputs.each { |input| abort "Missing #{input}" unless inputs.key?(input) }
(required_inputs - ["release_sha"]).each do |input|
  abort "Unsafe #{input} default" unless inputs.fetch(input).fetch("default") == false
end
abort "Write-capable GitHub permissions" unless data.fetch("permissions") == {"contents" => "read", "actions" => "read"}
abort "Unsafe concurrency cancellation" unless data.fetch("concurrency").fetch("cancel-in-progress") == false
env = data.fetch("env")
abort "Wrong Production project" unless env.fetch("PROJECT_REF") == "tcxvcatsqqertcnycuop"
abort "Function scope changed" unless env.fetch("FUNCTION_NAME") == "catalogue-ai-copy"
abort "Live version not pinned" unless env.fetch("EXPECTED_LIVE_VERSION").to_s == "44"
abort "Live bundle not pinned" unless env.fetch("EXPECTED_LIVE_BUNDLE_SHA") == "3e428098386b9d07aac360ae3e7955fa20fe4ab90fbe0ff14a6df43e4d6a1ffe"

jobs = data.fetch("jobs")
abort "Missing three-stage release" unless %w[contract preflight deploy].all? { |name| jobs.key?(name) }
abort "Read-only preflight environment missing" unless jobs.fetch("preflight").fetch("environment") == "supabase-production-readonly"
deploy_job = jobs.fetch("deploy")
abort "Independent Production environment missing" unless deploy_job.fetch("environment") == "supabase-production"

# Exact logical conjunction; mere substring checks allow || to bypass deploy=false.
expected = [
  "github.event_name == 'workflow_dispatch'",
  "inputs.deploy == true",
  "inputs.preview_uat_approved == true",
  "inputs.ai_disabled_verified == true",
  "inputs.rollback_approved == true",
].join(" && ")
abort "Release deploy predicate altered" unless deploy_job.fetch("if").gsub(/\s+/, " ").strip == expected

# No mandatory release check may silently become conditional or non-fatal.
abort "Workflow-level continue-on-error" if data["continue-on-error"]
%w[contract preflight deploy].each do |job_name|
  job = jobs.fetch(job_name)
  abort "Job-level continue-on-error: #{job_name}" if job["continue-on-error"]
  job.fetch("steps").each do |step|
    abort "Skipped required check: #{job_name}/#{step['name']}" if step.key?("if") && step.fetch("if") != "always()"
    abort "Non-fatal check: #{job_name}/#{step['name']}" if step["continue-on-error"]
    abort "Untrusted execution override" if step["shell"] && step["shell"] != "bash"
  end
end
abort "Unchecked job gating" if jobs.fetch("contract").key?("if") || jobs.fetch("preflight").key?("if")
contract_steps = jobs.fetch("contract").fetch("steps")
abort "Missing pre-checkout guard" unless contract_steps.first.fetch("name") == "Reject non-main dispatch before checking out or executing candidate code"
first_cmd = contract_steps.first.fetch("run")
abort "Missing protected-ref rejection" unless first_cmd.include?('test "$GITHUB_REF" = refs/heads/main') && first_cmd.include?('test "$GITHUB_SHA" = "$RELEASE_SHA"')
pre_steps = jobs.fetch("preflight").fetch("steps")
capture = pre_steps.find { |x| x["name"] == "Capture complete restorable live source and reviewed candidate closure" }
abort "Missing rollback capture" unless capture
cmd = capture.fetch("run")
abort "Missing post-download live pin" unless cmd.include?("live-after-download.json") && cmd.include?('".ezbr_sha256"') == false && cmd.include?("verify_jwt == true") && cmd.index("live-after-download.json") < cmd.index("capture-live-edge-function-rollback-artifacts.sh")
commands = jobs.values.flat_map { |job| job.fetch("steps") }.map { |step| step.fetch("run", "") }.join("\n")
abort "Secret mutation or schema write detected" if commands.match?(/supabase\s+(secrets\s+(?:set|unset)|db\s+push|migration\s+(?:up|repair))/)
abort "JWT verification must stay enabled" if commands.include?("--no-verify-jwt")
abort "No source-closure proof" unless commands.include?("edge-function-source-manifest.py")
abort "Missing deployed source comparison" unless commands.include?("cmp supabase/functions/catalogue-ai-copy/index.ts")
abort "Missing disabled-state source gate" unless commands.include?("AI_STUDIO_AI_ENABLED")
abort "Missing scoped Studio permission gate" unless commands.include?("has_ai_studio_permission_v1")
abort "Missing JWT-mode check" unless commands.include?("verify_jwt == true")
abort "No protected baseline check" unless commands.include?("EXPECTED_LIVE_BUNDLE_SHA")
abort "Missing post-write drift check" unless deploy_job.fetch("steps").find { |x| x["name"] == "Verify version, JWT and both deployed source files" }.fetch("run").include?('git rev-parse refs/remotes/origin/main')
# Inspect the ENTIRE deploy command line. CLI supports multiple function names.
deploy_commands = commands.lines.map(&:strip).select { |line| line.match?(/\bsupabase\s+functions\s+deploy\b/) }
expected_cmd = 'supabase functions deploy catalogue-ai-copy --project-ref "$PROJECT_REF" --use-api'
abort "Broad or altered function deploy invocation" unless deploy_commands == [expected_cmd]
puts "Catalogue AI copy protected named-function release contract passed."
