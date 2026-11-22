#!/usr/bin/env ruby
# Negative tests for single-function non-production deploy/delete contract.
require "tmpdir"
require "open3"
require "rbconfig"

source = File.read(".github/workflows/studio-ai-copy-qa-release.yml")
validator = File.expand_path("scripts/studio-qa/verify_release_hold.rb")
def check(ok, label)
  abort("STUDIO_QA_DEPLOY_NEGATIVE_TEST_FAILED: #{label}") unless ok
end
Dir.mktmpdir("studio-qa-deploy-") do |dir|
  target = File.join(dir, "candidate.yml")
  File.write(target, source)
  out, err, result = Open3.capture3(RbConfig.ruby, validator, target)
  check(result.success?, "baseline rejected #{out} #{err}")
  changes = {
    "production project" => ["QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: tcxvcatsqqertcnycuop"],
    "other function" => ["QA_FUNCTION_NAME: catalogue-ai-copy", "QA_FUNCTION_NAME: msg91-otp"],
    "automatic push" => ["  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"],
    "unprotected environment" => ["environment: genie-qa-bootstrap", "environment: production"],
    "unprotected branch" => ["github.ref == 'refs/heads/main'", "github.ref == 'refs/heads/dev'"],
    "weaken GitHub permission" => ["  contents: read", "  contents: write"],
    "remove concurrency discipline" => ["cancel-in-progress: false", "cancel-in-progress: true"],
    "allow persistent credentials" => ["persist-credentials: false", "persist-credentials: true"],
    "mutable checkout" => ["ref: ${{ github.sha }}", "ref: main"],
    "paid AI enabled" => ['AI_STUDIO_AI_ENABLED: "false"', 'AI_STUDIO_AI_ENABLED: "true"'],
    "disable JWT" => ["verify_jwt = true", "verify_jwt = false"],
    "no inert builder" => ["build_inert_copy.py", "build_unreviewed_copy.py"],
    "no source closure" => ['fileCount == 2', 'fileCount >= 1'],
    "no provider check" => ["! grep -RE", "grep -RE"],
    "wrong deployment token" => ["secrets.STUDIO_QA_DEPLOY_TOKEN", "secrets.SUPABASE_ACCESS_TOKEN"],
    "delete replaced by project delete" => ['supabase functions delete "$QA_FUNCTION_NAME"', 'supabase projects delete "$QA_PROJECT_REF"'],
    "deployment replaced by all" => ['supabase functions deploy "$QA_FUNCTION_NAME"', 'supabase functions deploy --all'],
    "no flag disable" => ['supabase secrets set --project-ref "$QA_PROJECT_REF" AI_STUDIO_AI_ENABLED=false', 'echo secret unmodified'],
    "no flag cleanup" => ['supabase secrets unset --project-ref "$QA_PROJECT_REF" AI_STUDIO_AI_ENABLED', 'echo secret persists'],
    "no JWT verification" => [".verify_jwt==true", ".verify_jwt==false"],
    "remove empty-after-delete check" => ["length==0", "length>=0"],
    "no CI policy" => ["ruby scripts/studio-qa/verify_release_hold.rb", "echo skip-security-policy"],
  }
  changes.each do |label, (needle, replacement)|
    check(source.include?(needle), "test anchor not present: #{label}")
    File.write(target, source.sub(needle, replacement))
    _stdout, _stderr, status = Open3.capture3(RbConfig.ruby, validator, target)
    check(!status.success?, "unsafe mutation passed: #{label}")
  end
end
puts "STUDIO_QA_EXECUTABLE_DEPLOY_DELETE_NEGATIVE_TESTS_PASS"
