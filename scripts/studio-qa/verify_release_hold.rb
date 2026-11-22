#!/usr/bin/env ruby
# Owner-authorized, executable QA-only release policy; legacy writer-token
# isolation explicitly waived for skhpmltfjgqitntkmclb, never Production.
require "yaml"

path = ARGV.fetch(0, ".github/workflows/studio-ai-copy-qa-release.yml")
def gate(ok, error)
  abort("STUDIO_QA_DEPLOY_CONTRACT_DENIED: #{error}") unless ok
end

raw = File.read(path)
data = YAML.safe_load(raw, aliases: false)
on = data.fetch("on", data[true])
gate(on.keys == ["workflow_dispatch"], "manual dispatch only")
inputs = on.fetch("workflow_dispatch").fetch("inputs")
gate(inputs.keys == ["operation"], "only deploy/delete input allowed")
gate(inputs["operation"]["required"] == true, "mandatory operation")
gate(inputs["operation"]["options"] == %w[deploy delete], "other operation allowed")
gate(data.fetch("permissions") == {"contents" => "read"}, "GitHub write privilege")
gate(data.fetch("concurrency").fetch("cancel-in-progress") == false, "cancellable deployment")
gate(data.fetch("jobs").keys == ["qa-function"], "unexpected job")
job = data["jobs"]["qa-function"]
gate(job["if"] == "github.repository == 'oasisbaklawa2006/oasis-supabase-core' && github.ref == 'refs/heads/main'", "not protected Core main")
gate(job["environment"] == "genie-qa-bootstrap", "not protected QA environment")
gate(job["runs-on"] == "ubuntu-24.04", "runner changed")
env = job.fetch("env")
gate(env["QA_PROJECT_REF"] == "skhpmltfjgqitntkmclb", "non-QA target")
gate(env["QA_FUNCTION_NAME"] == "catalogue-ai-copy", "non-Studio function")
gate(env["AI_STUDIO_AI_ENABLED"] == "false", "paid AI enabled")
gate(env["QA_OPERATION"] == '${{ inputs.operation }}', "operation input rewired")
gate(!env.values.join.include?("STUDIO_QA_DEPLOY_TOKEN"), "token exposed globally")
names = [
  "Verify fixed QA project and protected main",
  "Checkout immutable reviewed main",
  "Render pinned provider-inert QA source and run negative tests",
  "Install pinned Supabase CLI",
  "Deploy or delete only the QA catalogue-ai-copy function"
]
steps = job.fetch("steps")
gate(steps.map { |s| s["name"] } == names, "step addition/removal/reorder")
gate(steps.none? { |s| s.key?("if") || s["continue-on-error"] == true }, "skipped or tolerated step")
gate(steps[0]["shell"] == "bash", "unsafe guard shell")
guard = steps[0]["run"]
%w[GITHUB_REPOSITORY GITHUB_REF QA_PROJECT_REF QA_FUNCTION_NAME AI_STUDIO_AI_ENABLED QA_OPERATION].each do |item|
  gate(guard.include?(item), "missing identity guard")
end
gate(steps[1]["uses"] == "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd", "checkout not pinned")
gate(steps[1]["with"] == {"ref" => '${{ github.sha }}', "persist-credentials" => false}, "mutable checkout")
build = steps[2]["run"]
%w[verify_release_hold.rb test_studio_qa_release_hold.rb build_inert_copy.py
   test_studio_qa_ai_copy.py edge-function-source-manifest.py].each do |needle|
  gate(build.include?(needle), "inert source/test contract absent")
end
gate(build.include?("verify_jwt = true") && build.include?('fileCount == 2'),
     "JWT or source manifest weakened")
gate(build.include?('test "$(git rev-parse HEAD)" = "$GITHUB_SHA"'),
     "source not bound to reviewed commit")
gate(build.include?("OPENAI_API_KEY") && build.include?("api[.]openai[.]com") &&
     build.include?("! grep -RE"), "provider path not blocked")
gate(steps[3]["uses"] == "supabase/setup-cli@46f7f98c7f948ad727d22c1e67fab04c223a0520", "unpinned CLI")
gate(steps[3]["with"] == {"version" => '${{ env.CLI_VERSION }}'}, "unexpected CLI version")
gate(steps[4]["env"] == {"SUPABASE_ACCESS_TOKEN" => '${{ secrets.STUDIO_QA_DEPLOY_TOKEN }}'},
     "wrong deployment credential")
cmd = steps[4]["run"]
gate(cmd.start_with?("set -euo pipefail\n"), "non-failing release shell")
gate(cmd.include?('test "$QA_PROJECT_REF" = skhpmltfjgqitntkmclb') &&
     cmd.include?('test "$QA_FUNCTION_NAME" = catalogue-ai-copy') &&
     cmd.include?('test "$AI_STUDIO_AI_ENABLED" = false'), "QA-only guard missing")
gate(cmd.include?("AI_STUDIO_AI_ENABLED=false") &&
     cmd.include?('supabase secrets set --project-ref "$QA_PROJECT_REF"'),
     "QA AI flag not disabled")
gate(cmd.include?('supabase functions deploy "$QA_FUNCTION_NAME" --project-ref "$QA_PROJECT_REF" --use-api'),
     "named QA deployment missing")
gate(cmd.include?('supabase functions delete "$QA_FUNCTION_NAME" --project-ref "$QA_PROJECT_REF"'),
     "named QA rollback missing")
gate(cmd.include?("supabase secrets unset --project-ref") &&
     cmd.include?('if [[ "$QA_OPERATION" == deploy ]]; then'), "missing delete cleanup")
gate(cmd.include?('length==0') && cmd.include?('.verify_jwt==true') &&
     cmd.include?('.slug=="catalogue-ai-copy"') &&
     cmd.include?('"https://api.supabase.com/v1/projects/$QA_PROJECT_REF/functions"'),
     "before/after exact QA validation absent")
gate(!cmd.match?(/supabase\s+(?:db\s+|projects\s+delete|migration\s+|functions\s+deploy\s+--all)/),
     "unrelated Supabase write command")
gate(!raw.include?("tcxvcatsqqertcnycuop") &&
     !raw.include?("supabase-production") && !raw.include?("OPENAI_API_KEY="),
     "Production reference or provider credential")
puts "STUDIO_QA_EXECUTABLE_DEPLOY_DELETE_CONTRACT_PASS"
