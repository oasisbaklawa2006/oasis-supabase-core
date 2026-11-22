#!/usr/bin/env ruby
# Static security contract: Studio QA release modes remain blocked until
# independently certified Supabase external-writer isolation and another PR.
require "yaml"

path = ARGV.fetch(0, ".github/workflows/studio-ai-copy-qa-release.yml")
def gate(condition, error)
  abort("STUDIO_QA_RELEASE_HOLD_DENIED: #{error}") unless condition
end

yaml = YAML.safe_load(File.read(path), aliases: false)
trigger = yaml.fetch("on", yaml[true])
gate(trigger.keys == ["workflow_dispatch"], "not manual-only")
inputs = trigger.fetch("workflow_dispatch").fetch("inputs")
gate(inputs.keys.sort == %w[change_reference expected_head_sha operation owner_authorization preflight_run_id],
     "unexpected dispatch arguments")
gate(inputs.fetch("operation").fetch("default") == "preflight", "not inert by default")
gate(inputs.fetch("operation").fetch("options") == %w[preflight deploy rollback], "mode drift")
gate(yaml.fetch("permissions") == {"contents" => "read", "actions" => "read"}, "GitHub write privileges")
gate(yaml.fetch("concurrency").fetch("cancel-in-progress") == false, "cancellable release")

jobs = yaml.fetch("jobs")
gate(jobs.keys == ["named-qa-release"], "unexpected job")
job = jobs.fetch("named-qa-release")
gate(job.fetch("if") == "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'", "repo/main gate removed")
gate(job.fetch("runs-on") == "ubuntu-24.04", "runner drift")
gate(job.fetch("environment") == "genie-qa-bootstrap", "missing protected QA environment")
env = job.fetch("env")
gate(env.fetch("QA_PROJECT_REF") == "skhpmltfjgqitntkmclb", "foreign QA target")
gate(env.fetch("QA_FUNCTION_NAME") == "catalogue-ai-copy", "function scope drift")
gate(!env.values.join.include?("STUDIO_QA_DEPLOY_TOKEN"), "global release token exposure")

steps = job.fetch("steps")
expected_names = [
  "Confirm exact protected commit and release inputs",
  "Check out immutable reviewed main source",
  "Run reviewed source and release workflow negative tests",
  "Bind trusted same-commit approved preflight",
  "Inspect current QA Edge and provider secrets without write access",
  "Block live Edge mutation until external writer access is independently controlled",
  "Held exact QA deployment and rollback mechanism"
]
gate(steps.map { |s| s.fetch("name") } == expected_names, "steps missing or out of order")
gate(steps[0].fetch("run").include?('test "$GITHUB_SHA" = "$EXPECTED_SHA"'), "unbound GitHub source")
gate(steps[0].fetch("run").include?('commits/main'), "mutable main check missing")
gate(steps[1].fetch("uses") == "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd", "checkout drift")
gate(steps[1].fetch("with") == {
  "ref" => '${{ github.sha }}', "persist-credentials" => false
}, "untrusted checkout")
gate(steps[2].fetch("run").include?("build_inert_copy.py") &&
     steps[2].fetch("run").include?("verify_release_hold.rb") &&
     steps[2].fetch("run").include?("test_studio_qa_release_hold.rb") &&
     steps[2].fetch("run").include?("verify_jwt = true") &&
     steps[2].fetch("run").include?('fileCount == 2'), "source/JWT proof missing")
gate(steps[3].fetch("run").include?("studio-ai-copy-qa-preflight.yml") &&
     steps[3].fetch("run").include?(".head_sha == $sha") &&
     steps[3].fetch("run").include?("workflow_dispatch") &&
     steps[3].fetch("run").include?("conclusion == \"success\""), "independent preflight provenance missing")
gate(steps[4].fetch("env") == {"SUPABASE_ACCESS_TOKEN" => '${{ secrets.SUPABASE_ACCESS_TOKEN }}'},
     "read-only credential changed")
gate(steps[4].fetch("run").include?("verify_secrets.py") &&
     steps[4].fetch("run").include?("length == 0") &&
     steps[4].fetch("run").include?("catalogue-ai-copy"), "pre-release inventory missing")
gate(steps[5].fetch("run").include?('if [[ "$RELEASE_OPERATION" != preflight ]]; then') &&
     steps[5].fetch("run").include?("STUDIO_QA_EXTERNAL_WRITER_CONTROL_UNVERIFIED") &&
     steps[5].fetch("run").include?("exit 1"), "mandatory writer hold removed")
gate(steps[5].fetch("shell") == "bash", "hard stop shell drift")
gate(steps[5]["continue-on-error"] != true && !steps[5].key?("if"), "hard stop bypassed")
gate(steps[6].fetch("if") == "inputs.operation != 'preflight'", "writer step condition drift")
gate(steps[6].fetch("env") == {"SUPABASE_ACCESS_TOKEN" => '${{ secrets.STUDIO_QA_DEPLOY_TOKEN }}'},
     "deployment token exposure")
gate(steps[6].fetch("run").include?("STUDIO_QA_REMOTE_SOURCE_ATTESTATION_NOT_YET_APPROVED") &&
     steps[6].fetch("run").include?("STUDIO_QA_ROLLBACK_CLEANUP_NOT_YET_APPROVED") &&
     steps[6].fetch("run").include?("exit 1"), "held writer step not fail-closed")
gate(steps[0...6].none? { |step| (step.fetch("env", {}).values.join.include?("STUDIO_QA_DEPLOY_TOKEN")) },
     "write token used before hold")
gate(steps.none? { |step| step["continue-on-error"] == true }, "failed release step not fatal")
puts "STUDIO_QA_RELEASE_HOLD_STATIC_PASS"
