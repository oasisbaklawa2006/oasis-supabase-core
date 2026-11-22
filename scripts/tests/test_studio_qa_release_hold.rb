#!/usr/bin/env ruby
# Negative tests: the one approved QA-only workflow may deploy/rollback,
# but cannot silently change target, source, JWT, spend flag or cleanup.
require "tmpdir"
require "open3"
require "rbconfig"

original = File.read(".github/workflows/studio-ai-copy-qa-release.yml")
policy = File.expand_path("scripts/studio-qa/verify_release_hold.rb")
def test_gate(ok, message)
  abort("STUDIO_QA_RELEASE_NEGATIVE_TEST_FAILED: #{message}") unless ok
end

Dir.mktmpdir("studio-qa-executable-policy-") do |dir|
  candidate = File.join(dir, "workflow.yml")
  File.write(candidate, original)
  out, err, status = Open3.capture3(RbConfig.ruby, policy, candidate)
  test_gate(status.success?, "approved workflow rejected: #{out} #{err}")
  mutations = {
    "foreign target" => ["QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: tcxvcatsqqertcnycuop"],
    "foreign function" => ["QA_FUNCTION_NAME: catalogue-ai-copy", "QA_FUNCTION_NAME: unrelated-function"],
    "unprotected environment" => ["environment: genie-qa-bootstrap", "environment: production"],
    "automatic trigger" => ["  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"],
    "GitHub write permissions" => ["  contents: read", "  contents: write"],
    "mutable checkout" => ["ref: ${{ github.sha }}", "ref: main"],
    "persist checkout credential" => ["persist-credentials: false", "persist-credentials: true"],
    "JWT disabled" => ["verify_jwt = true", "verify_jwt = false"],
    "disabled flag made true" => ["AI_STUDIO_AI_ENABLED=false", "AI_STUDIO_AI_ENABLED=true"],
    "lost disabled flag" => ["supabase secrets set", "supabase secrets echo"],
    "delete flag cleanup lost" => ["supabase secrets unset", "supabase secrets show"],
    "remove source builder" => ["build_inert_copy.py", "unreviewed-builder.py"],
    "source hash gate removed" => ["edge-function-source-manifest.py", "unreviewed-manifest.py"],
    "remote attestation removed" => ["verify_qa_bundle.py", "ignore_remote_bundle.py"],
    "delete function removed" => ['functions delete "$QA_FUNCTION_NAME"', 'functions delete "different-function"'],
    "deploy function removed" => ['functions deploy "$QA_FUNCTION_NAME"', 'functions deploy "different-function"'],
    "deploy command foreign project only" => ['--project-ref "$QA_PROJECT_REF" --use-api --yes', '--project-ref tcxvcatsqqertcnycuop --use-api --yes'],
    "no-verify-jwt flag on separate write" => ['supabase secrets set AI_STUDIO_AI_ENABLED=false --project-ref "$QA_PROJECT_REF" --yes', 'supabase secrets set AI_STUDIO_AI_ENABLED=false --project-ref "$QA_PROJECT_REF" --yes --no-verify-jwt'],
    "prune flag on separate write" => ['supabase secrets set AI_STUDIO_AI_ENABLED=false --project-ref "$QA_PROJECT_REF" --yes', 'supabase secrets set AI_STUDIO_AI_ENABLED=false --project-ref "$QA_PROJECT_REF" --yes --prune'],
    "rollback zero inventory rejected" => ['length == 0 or (length == 1 and .[0].slug == "catalogue-ai-copy")', 'length == 1 and .[0].slug == "catalogue-ai-copy"'],
    "rollback unconditional deletion" => ['if jq -e \'length == 1\' "$before" >/dev/null; then', 'if true; then'],
    "rollback secret cleanup not idempotent" => ['any(.[]; .name == "AI_STUDIO_AI_ENABLED")', 'any(.[]; .name == "UNRELATED_SECRET")'],
    "disable operations" => ["options: [deploy, rollback]", "options: [preflight]"],
    "remove Edge-zero confirmation" => ["STUDIO_QA_FUNCTION_DELETED_AND_SECRETS_RESTORED", "STUDIO_QA_INCOMPLETE_ROLLBACK"],
    "turn off whole error propagation" => ["          set -euo pipefail\n          test", "          set +e\n          test"]
  }
  mutations.each do |label, (before, after)|
    test_gate(original.include?(before), "missing negative test anchor: #{label}")
    File.write(candidate, original.sub(before, after))
    _out, _err, result = Open3.capture3(RbConfig.ruby, policy, candidate)
    test_gate(!result.success?, "unsafe change passed policy: #{label}")
  end
end
puts "STUDIO_QA_RELEASE_EXECUTABLE_NEGATIVE_TESTS_PASS"
