#!/usr/bin/env ruby
# Credential-free, strict contract for the named staff-provisioner production update.
# Parse YAML rather than grepping text/comments: a quoted event key is still an event.
require "yaml"

def assert!(condition, message)
  abort("STAFF PROVISION RELEASE CONTRACT: #{message}") unless condition
end

path = ARGV.fetch(0, ".github/workflows/admin-provision-user-protected-update.yml")
config_path = ARGV.fetch(1, "supabase/config.toml")
doc = YAML.safe_load(File.read(path), aliases: false)
assert!(doc.is_a?(Hash), "workflow must be a YAML mapping")
triggers = doc.fetch("on", doc[true])
assert!(triggers.is_a?(Hash) && triggers.keys == ["workflow_dispatch"],
        "production update must have exactly one manual dispatch trigger")
inputs = triggers.fetch("workflow_dispatch").fetch("inputs")
assert!(inputs.is_a?(Hash), "manual dispatch inputs must be a mapping")
%w[release_sha deploy staff_caller_certified redirect_allowlisted
   email_config_certified rollback_approved approved_origin_sha256].each do |key|
  assert!(inputs.key?(key), "missing protected dispatch input: #{key}")
end

jobs = doc.fetch("jobs")
assert!(jobs.is_a?(Hash), "jobs mapping missing")
%w[contract preflight deploy].each { |name| assert!(jobs[name].is_a?(Hash), "missing job #{name}") }
assert!(jobs.fetch("preflight").fetch("environment") == "supabase-production-readonly",
        "preflight must bind exact read-only protected environment")
assert!(jobs.fetch("deploy").fetch("environment") == "supabase-production",
        "deploy must bind exact production approval environment")
assert!(jobs.fetch("preflight").fetch("needs") == "contract", "preflight must depend on contract")
assert!(jobs.fetch("deploy").fetch("needs") == "preflight", "deploy must depend on preflight")
assert!(jobs.fetch("preflight").fetch("if") == "github.event_name == 'workflow_dispatch'",
        "preflight must be manual dispatch only")
required_deploy_if = "github.event_name == 'workflow_dispatch' && inputs.deploy == true && " \
  "inputs.staff_caller_certified == true && inputs.redirect_allowlisted == true && " \
  "inputs.email_config_certified == true && inputs.rollback_approved == true"
assert!(jobs.fetch("deploy").fetch("if") == required_deploy_if,
        "deploy condition must contain every required certification, with no alternatives")
assert!(doc.dig("env", "FUNCTION_NAME") == "admin-provision-user", "unexpected function target")
assert!(doc.dig("env", "EXPECTED_LIVE_VERSION").to_s == "5", "live version baseline changed")
assert!(doc.dig("env", "EXPECTED_LIVE_BUNDLE_SHA") ==
  "7bb177f6a3e4d6cd429be0b64d76ba9ec36492d686e359bba4c0c4c6e957ad84",
  "v5 bundle fingerprint changed")
assert!(doc.dig("concurrency", "group") == "admin-provision-user-production-first-deploy",
        "staff first-deploy/remove/update writers must share one serial concurrency group")
assert!(doc.dig("concurrency", "cancel-in-progress") == false,
        "a concurrent workflow must not cancel a protected release")

# Validate parsed shell block scalars after joining Bash continuations. A command
# split across multiple physical lines is still a single effective command.
script_texts = {}
jobs.each do |job_name, job|
  next unless job.is_a?(Hash)
  steps = job["steps"] || []
  assert!(steps.is_a?(Array), "invalid step collection")
  script_texts[job_name] = steps.filter_map { |step| step["run"] if step.is_a?(Hash) }
end
all_scripts = script_texts.values.flatten.join("\n")
normalized = all_scripts.gsub(/\\[ \t]*\n/, " ").lines.reject { |line| line.lstrip.start_with?("#") }.join
assert!(!normalized.match?(/\bsupabase\s+(?:--[\w-]+\s+(?:"[^"]*"|\S+)\s+)*secrets\s+(?:set|unset)\b/i),
        "production secret write is forbidden, even across shell continuations")
assert!(!normalized.include?("--no-verify-jwt"), "JWT verification must remain enabled")
deploy_commands = normalized.scan(/\bsupabase\s+functions\s+deploy\s+([a-z0-9-]+)/i).flatten
assert!(deploy_commands == ["admin-provision-user"],
        "only one named admin-provision-user deploy is allowed")
assert!(!script_texts.fetch("contract").join("\n").include?("SUPABASE_ACCESS_TOKEN"),
        "credential-free contract may not reference production access token")
assert!(script_texts.fetch("deploy").join("\n").include?("live-immediate-before-write.json"),
        "a fresh live baseline is mandatory immediately before the write")
assert!(script_texts.fetch("deploy").join("\n").include?("approved-origin-sha256.txt"),
        "deploy must bind approved origin digest to the archived preflight")
assert!(script_texts.fetch("preflight").join("\n").include?("approved-origin-sha256.txt"),
        "preflight must archive a digest of the configured origin")
archive_step = jobs.fetch("preflight").fetch("steps").find { |step| step["id"] == "archive_preflight" }
archive_paths = archive_step&.dig("with", "path")&.split("\n")&.map(&:strip) || []
assert!(archive_paths.include?("approved-origin-sha256.txt"),
        "preflight must upload the approved origin digest in its immutable archive")
config = File.read(config_path)
section = config.match(/^\[functions\.admin-provision-user\]\s*$([\s\S]*?)(?=^\[|\z)/)
assert!(!section.nil? && section[1].match?(/^\s*verify_jwt\s*=\s*true\s*$/),
        "retain existing admin-provision-user config with verify_jwt=true")
# A completed write must be independently verifiable without replaying a write.
verifier_path = ARGV.fetch(2, ".github/workflows/admin-provision-user-protected-verify.yml")
verifier = YAML.safe_load(File.read(verifier_path), aliases: false)
assert!(verifier.is_a?(Hash), "read-only verifier must be a YAML mapping")
verification_events = verifier.fetch("on", verifier[true])
assert!(verification_events.is_a?(Hash) && verification_events.keys == ["workflow_dispatch"],
        "read-only recovery must be manual-only")
assert!(verifier.dig("concurrency", "group") == doc.dig("concurrency", "group"),
        "verification must be serialized with staff provisioning writers")
assert!(verifier.fetch("jobs").keys == ["verify"], "recovery may have only one verify job")
verify_job = verifier.dig("jobs", "verify")
assert!(verify_job["environment"] == "supabase-production-readonly",
        "recovery cannot bind the production write environment")
verify_scripts = verify_job.fetch("steps").filter_map { |step| step["run"] }.join("\n")
assert!(!verify_scripts.match?(/\bsupabase\s+functions\s+(deploy|delete)\b/i),
        "read-only recovery must never deploy or delete a function")
assert!(verify_scripts.include?("recovery-live-sanitized.json") &&
        verify_scripts.include?("recovered-source/supabase/functions"),
        "recovery must capture sanitized metadata and compare source")
assert!(verify_scripts.include?('test "$code" = "401"'),
        "recovery must include invalid-authorization rejection")
verify_step_runs = verify_scripts.gsub(/\\[ \t]*\n/, " ")
assert!(!verify_step_runs.match?(/\bsupabase\s+secrets\s+(set|unset)\b/i),
        "recovery must never mutate secrets")

release_scripts = script_texts.fetch("deploy").join("\n")
metadata_pos = release_scripts.index("live-after-sanitized.json")
download_pos = release_scripts.index("mkdir -p deployed-source")
assert!(!metadata_pos.nil? && !download_pos.nil? && metadata_pos < download_pos,
        "save sanitized live result before verifying downloaded source")
assert!(release_scripts.include?("($prior + 1)"),
        "deployment must expect exactly one version advancement")
assert!(script_texts.fetch("preflight").join("\n").include?("origin-inventory.json"),
        "preflight must fail closed on missing secret inventory metadata")
puts("STAFF PROVISION RELEASE CONTRACT VERIFIED (parsed triggers, job environments, attestation guards, digest, recovery and commands)")
