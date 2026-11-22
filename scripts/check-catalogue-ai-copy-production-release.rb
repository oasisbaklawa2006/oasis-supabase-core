#!/usr/bin/env ruby
# Credential-free regression: a protected named-function workflow may never silently widen.
require "yaml"

workflow_path = ".github/workflows/catalogue-ai-copy-production-release.yml"
data = YAML.safe_load(File.read(workflow_path), aliases: false)
abort "Missing release workflow" unless data.is_a?(Hash)
trigger = data.fetch("on", data[true])
abort "Manual dispatch only" unless trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"]
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
%w[release_sha deploy preview_uat_approved ai_disabled_verified rollback_approved].each do |input|
  abort "Missing #{input}" unless inputs.key?(input)
end
%w[deploy preview_uat_approved ai_disabled_verified rollback_approved].each do |input|
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
abort "Missing 3-stage release" unless %w[contract preflight deploy].all? {|name| jobs.key?(name)}
abort "Read-only preflight environment missing" unless jobs.fetch("preflight").fetch("environment") == "supabase-production-readonly"
deploy_job = jobs.fetch("deploy")
abort "Independent Production environment missing" unless deploy_job.fetch("environment") == "supabase-production"
condition = deploy_job.fetch("if")
%w[inputs.deploy inputs.preview_uat_approved inputs.ai_disabled_verified inputs.rollback_approved].each do |term|
  abort "Missing protected deploy predicate #{term}" unless condition.include?("#{term} == true")
end
commands = jobs.values.flat_map {|job| job.fetch("steps")}.map {|step| step.fetch("run", "")}.join("\n")
abort "Broad deployment detected" unless commands.scan(/supabase functions deploy\s+catalogue-ai-copy\b/).length == 1
abort "Secret mutation or schema write detected" if commands.match?(/supabase\s+(secrets\s+(?:set|unset)|db\s+push|migration\s+(?:up|repair))/)
abort "JWT verification must stay enabled" if commands.include?("--no-verify-jwt")
abort "No source-closure proof" unless commands.include?("edge-function-source-manifest.py")
abort "No rollback capture" unless commands.include?("capture-live-edge-function-rollback-artifacts.sh")
abort "Missing deployed source comparison" unless commands.include?("cmp supabase/functions/catalogue-ai-copy/index.ts")
abort "Missing disabled-state source gate" unless commands.include?("AI_STUDIO_AI_ENABLED")
abort "Missing scoped Studio permission gate" unless commands.include?("has_ai_studio_permission_v1")
abort "Missing JWT-mode check" unless commands.include?("verify_jwt == true")
abort "No protected baseline check" unless commands.include?("EXPECTED_LIVE_BUNDLE_SHA")
puts "Catalogue AI copy named-function protected release contract passed."
