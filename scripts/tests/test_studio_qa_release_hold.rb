#!/usr/bin/env ruby
# Fail-closed negative cases for the protected Studio named-function release.
require "tmpdir"
require "open3"
require "rbconfig"

src = File.read(".github/workflows/studio-ai-copy-qa-release.yml")
verifier = File.expand_path("scripts/studio-qa/verify_release_hold.rb")
def assert_test(ok, detail)
  abort("STUDIO_QA_RELEASE_NEGATIVE_TEST_FAILED: #{detail}") unless ok
end

Dir.mktmpdir("studio-release-hold-") do |dir|
  path = File.join(dir, "release.yml")
  File.write(path, src)
  o, e, status = Open3.capture3(RbConfig.ruby, verifier, path)
  assert_test(status.success?, "approved baseline rejected: #{o} #{e}")
  changes = {
    "wrong project" => ["QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: tcxvcatsqqertcnycuop"],
    "wrong function" => ["QA_FUNCTION_NAME: catalogue-ai-copy", "QA_FUNCTION_NAME: msg91-otp"],
    "unprotected environment" => ["environment: genie-qa-bootstrap", "environment: production"],
    "push trigger" => ["  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"],
    "persistent checkout credential" => ["persist-credentials: false", "persist-credentials: true"],
    "wrong source" => ["ref: ${{ github.sha }}", "ref: main"],
    "weak JWT" => ["verify_jwt = true", "verify_jwt = false"],
    "no preflight" => ["studio-ai-copy-qa-preflight.yml", "other-workflow.yml"],
    "preflight changed head" => [".head_sha == $sha", ".id == $sha"],
    "no secret inventory" => ["verify_secrets.py", "verify_other.py"],
    "no Edge zero" => ["length == 0", "length >= 0"],
    "hold removed" => ["if [[ \"$RELEASE_OPERATION\" != preflight ]]; then\n            echo '::error::STUDIO_QA_EXTERNAL_WRITER_CONTROL_UNVERIFIED'", "if [[ \"$RELEASE_OPERATION\" == preflight ]]; then\n            echo '::error::STUDIO_QA_EXTERNAL_WRITER_CONTROL_UNVERIFIED'"],
    "hold error removed" => ["STUDIO_QA_EXTERNAL_WRITER_CONTROL_UNVERIFIED", "STUDIO_QA_EXTERNAL_WRITER_CONTROL_ALLOWED"],
    "deployment token leak" => ["secrets.SUPABASE_ACCESS_TOKEN", "secrets.STUDIO_QA_DEPLOY_TOKEN"],
    "direct deploy default" => ["default: preflight", "default: deploy"],
    "bypass failure" => ["          exit 1\n          fi\n          test", "          true\n          fi\n          test"],
  }
  changes.each do |label, (before, after)|
    assert_test(src.include?(before), "negative test anchor missing: #{label}")
    File.write(path, src.sub(before, after))
    _out, _err, code = Open3.capture3(RbConfig.ruby, verifier, path)
    assert_test(!code.success?, "unsafe change passed: #{label}")
  end
end

puts "STUDIO_QA_RELEASE_HOLD_NEGATIVE_TESTS_PASS"
