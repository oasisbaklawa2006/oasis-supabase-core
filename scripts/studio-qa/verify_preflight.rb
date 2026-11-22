#!/usr/bin/env ruby
# Protected read-only Studio QA guard. Fail-closed before any QA writer is added.
require "yaml"

file = ARGV.fetch(0, ".github/workflows/studio-ai-copy-qa-preflight.yml")
data = YAML.safe_load(File.read(file), aliases: false)
def require_gate(test, message)
  abort("STUDIO_QA_WORKFLOW_DENIED: #{message}") unless test
end
require_gate(data.is_a?(Hash), "YAML root missing")
trigger = data.fetch("on", data[true])
require_gate(trigger.is_a?(Hash) && trigger.keys == ["workflow_dispatch"], "manual-only")
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
require_gate(inputs.keys.sort == %w[change_reference expected_head_sha], "unexpected inputs")
require_gate(inputs.values.all? {|x| x.fetch("required") == true}, "missing mandatory inputs")
require_gate(data.fetch("permissions") == {"contents"=>"read"}, "write-capable GitHub permissions")
require_gate(data.fetch("concurrency").fetch("cancel-in-progress") == false, "unsafe concurrency")
jobs = data.fetch("jobs")
require_gate(jobs.keys == ["preflight"], "unexpected deployment/recovery job")
job = jobs.fetch("preflight")
condition = "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'"
require_gate(job.fetch("if") == condition, "missing main/repo dispatch gate")
require_gate(job.fetch("environment") == "genie-qa-bootstrap", "unprotected QA environment")
require_gate(job.fetch("runs-on") == "ubuntu-24.04", "runner changed")
require_gate(job.fetch("env").fetch("QA_PROJECT_REF") == "skhpmltfjgqitntkmclb", "QA target changed")
require_gate(job.fetch("env").fetch("QA_MIGRATION_SOURCE_SHA") == "a4ec8aafc41afa14717c092e583ebb697fe000ef", "QA schema root changed")
require_gate(!job["continue-on-error"] && !data["continue-on-error"], "ignored job failure")
steps = job.fetch("steps")
steps.each do |s|
  require_gate(!s["continue-on-error"] && !s.key?("if"), "skipped/nonfatal mandatory step")
  require_gate(!s.key?("shell") || s.fetch("shell") == "bash", "unexpected shell")
end
require_gate(steps.first.fetch("name") == "Require exact current protected main before running candidate code", "pre-checkout gate removed")
require_gate(steps.first.fetch("run").include?('test "$GITHUB_SHA" = "$EXPECTED_SHA"'), "exact commit gate missing")
require_gate(steps.first.fetch("run").include?('gh api "repos/$GITHUB_REPOSITORY/commits/main"'), "current main check missing")
checkout = steps.find {|s| s["name"] == "Check out reviewed Core main at workflow SHA"}
require_gate(checkout && checkout.fetch("with").fetch("ref") == "${{ github.sha }}", "untrusted checkout ref")
source = steps.find {|s| s["name"] == "Verify source contract and render provider-inert QA bundle"}
require_gate(source, "inert source missing")
source_run = source.fetch("run")
%w[build_inert_copy.py edge-function-source-manifest.py catalogueAiCopy.ts].each do |token|
  require_gate(source_run.include?(token) || (token == "catalogueAiCopy.ts" && source_run.include?("_shared")), "missing approved source guard")
end
require_gate(source_run.include?("verify_jwt = true"), "JWT gate missing")
require_gate(source_run.include?('grep -Erq') &&
  source_run.include?('"$RUNNER_TEMP/studio-copy/supabase/functions"') &&
  source_run.include?('test "$scan_status" -eq 1'), "fail-closed full closure provider scan missing")
schema = steps.find {|s| s["name"] == "Prove isolated QA canonical schema and zero synthetic staff"}
require_gate(schema, "no QA database proof")
run = schema.fetch("run")
require_gate(schema.fetch("env").fetch("PGOPTIONS") == "-c default_transaction_read_only=on",
  "database session is not forced read-only")
require_gate(!run.match?(/\b(?:INSERT|UPDATE|DELETE|CREATE|DROP|ALTER|TRUNCATE|MERGE|GRANT|REVOKE|CALL|DO|COPY|UPSERT)\b/i),
  "SQL mutation statement is forbidden")
%w[516 392 auth.users auth.sessions auth.refresh_tokens has_ai_studio_permission_v1
   is_internal_staff pg_cron pg_net dblink pg_catalog].each do |token|
  require_gate(run.include?(token), "QA schema/egress proof incomplete")
end
secrets = steps.find {|s| s["name"] == "Check QA-only provider-secret absence and zero deployed functions"}
require_gate(secrets && secrets.fetch("run").include?("verify_secrets.py"), "missing provider inventory denial")
require_gate(secrets.fetch("run").include?('length == 0'), "shared QA Edge must start empty")
# Pin the *entire* secret-bearing step, not merely curl. Otherwise Python,
# Node or other HTTP clients could be inserted while satisfying a curl check.
approved_qa_secret_script = <<~'STUDIO_QA_READONLY_SCRIPT'
  set -euo pipefail
  test "$QA_PROJECT_REF" = skhpmltfjgqitntkmclb
  test -n "$SUPABASE_ACCESS_TOKEN"
  curl --fail --silent --show-error --max-time 30             -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN"             "https://api.supabase.com/v1/projects/$QA_PROJECT_REF/secrets"             > "$RUNNER_TEMP/studio-qa-secrets.json"
  chmod 600 "$RUNNER_TEMP/studio-qa-secrets.json"
  python3 -I scripts/studio-qa/verify_secrets.py             "$RUNNER_TEMP/studio-qa-secrets.json"
  curl --fail --silent --show-error --max-time 30             -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN"             "https://api.supabase.com/v1/projects/$QA_PROJECT_REF/functions"             > "$RUNNER_TEMP/studio-qa-functions.json"
  jq -e 'type == "array" and length == 0'             "$RUNNER_TEMP/studio-qa-functions.json" >/dev/null || {
      echo '::error::STUDIO_QA_EDGE_RUNTIME_NOT_EMPTY_OR_GENIE_RESERVED'; exit 1;
    }
  echo STUDIO_QA_PROVIDER_AND_EDGE_EMPTY_PASS
STUDIO_QA_READONLY_SCRIPT
require_gate(secrets.fetch("env") == {"SUPABASE_ACCESS_TOKEN" => "${{ secrets.SUPABASE_ACCESS_TOKEN }}"},
  "unexpected secret-bearing step environment")
require_gate(secrets.fetch("run") == approved_qa_secret_script,
  "QA secret-reading step changed outside its exact reviewed read-only contents")
require_gate(steps.any? {|s| s["name"] == "Install QA CA and validate direct-connection target without mutation" && s.fetch("run").include?('mode="apply"')}, "no direct QA-only TLS target guard")
require_gate(steps.any? {|s| s["name"] == "Assert no QA or Production mutations and report next protected gate" }, "missing terminal no-write gate")
cmds = steps.map {|s| s.fetch("run", "")}.join("\n")
require_gate(!cmds.match?(/supabase\s+(?:functions\s+deploy|db\s+push|migration\s+(?:up|repair)|secrets\s+(?:set|unset))/), "remote deploy/schema/secret write detected")
# Only two explicitly guarded Supabase Management API GETs may use curl.
# Prevent other CLI clients (wget --post-data, HTTPie, etc.) from bypassing
# tool-specific curl checks or changing the read-only workflow into an HTTP writer.
require_gate(!cmds.match?(/\b(?:wget|httpie|aria2c)\b/i), "unapproved HTTP client")
# Only the two precisely reviewed GET requests are permitted. A blacklist of
# curl flags is not sound: attached options (-XPOST / -dVALUE), config files,
# implicit POST flags, or shell continuations can bypass a token-only regex.
# Normalize harmless whitespace, then require literal command equality.
normalized_curl_commands = [
  'curl --fail --silent --show-error --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "https://api.supabase.com/v1/projects/$QA_PROJECT_REF/secrets" > "$RUNNER_TEMP/studio-qa-secrets.json"',
  'curl --fail --silent --show-error --max-time 30 -H "Authorization: Bearer $SUPABASE_ACCESS_TOKEN" "https://api.supabase.com/v1/projects/$QA_PROJECT_REF/functions" > "$RUNNER_TEMP/studio-qa-functions.json"'
].sort
all_curl_occurrences = cmds.scan(/\bcurl\b/).length
actual_curl_commands = cmds.gsub(/\\\r?\n[ \t]*/, ' ').lines
  .map { |line| line.strip.gsub(/[ \t]+/, ' ') }
  .select { |line| line.start_with?('curl ') }
  .sort
require_gate(all_curl_occurrences == 2 && actual_curl_commands == normalized_curl_commands,
  "only the two approved read-only QA Management API GET commands may use curl")
require_gate(!cmds.include?("|| true") && !cmds.include?("set +e"), "fail-open command")
require_gate(cmds.include?("STUDIO_QA_PREFLIGHT_PASS"), "no truthful preflight marker")
puts "STUDIO_QA_READONLY_WORKFLOW_PASS"
