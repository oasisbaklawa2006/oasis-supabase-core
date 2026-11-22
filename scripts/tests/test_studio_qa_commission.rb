#!/usr/bin/env ruby
# Negative tests prove that security-critical commissioning changes fail closed.
require "open3"
require "tmpdir"
require "rbconfig"

workflow = File.read(".github/workflows/studio-ai-copy-qa-commission.yml")
validator = File.expand_path("scripts/studio-qa/verify_commission.rb")
def check(condition, description)
  abort("STUDIO_QA_COMMISSION_TEST_FAIL: #{description}") unless condition
end

Dir.mktmpdir("studio-qa-commission-tests-") do |dir|
  candidate = File.join(dir, "workflow.yml")
  File.write(candidate, workflow)
  stdout, stderr, status = Open3.capture3(RbConfig.ruby, validator, candidate)
  check(status.success?, "baseline rejected: #{stdout} #{stderr}")

  mutations = {
    "wrong QA target" => ["QA_PROJECT_REF: skhpmltfjgqitntkmclb", "QA_PROJECT_REF: tcxvcatsqqertcnycuop"],
    "change protected environment" => ["environment: genie-qa-bootstrap", "environment: production"],
    "enable push trigger" => ["  workflow_dispatch:", "  push:\n    branches: [main]\n  workflow_dispatch:"],
    "weaken checkout" => ["ref: ${{ github.sha }}", "ref: main"],
    "grant write rights" => ["  contents: read", "  contents: write"],
    "permit deployment mode" => ['if [[ "$RELEASE_MODE" != readiness ]]; then', 'if [[ "$RELEASE_MODE" == readiness ]]; then'],
    "remove hard stop" => ["            exit 1\n", "            true\n"],
    "remove protected preflight binding" => [".head_sha == $sha", ".head_id == $sha"],
    "remove Edge-zero check" => ['length == 0', 'length >= 0'],
    "remove secret inventory" => ["verify_secrets.py", "ignored_secrets.py"],
    "permit HTTP POST" => ["          echo STUDIO_QA_CURRENT_SECRETS_AND_EDGE_ZERO_PASS", "          curl -X POST https://api.supabase.com/v1/projects/example/functions\n          echo STUDIO_QA_CURRENT_SECRETS_AND_EDGE_ZERO_PASS"],
    "consume deploy token" => ["secrets.SUPABASE_ACCESS_TOKEN", "secrets.STUDIO_QA_DEPLOY_TOKEN"],
    "disable JWT" => ["verify_jwt = true", "verify_jwt = false"],
    "make policy optional" => ["          ruby scripts/studio-qa/verify_commission.rb", "          true # validator omitted"],
  }

  mutations.each do |description, (old, replacement)|
    check(workflow.include?(old), "test anchor missing: #{description}")
    modified = workflow.sub(old, replacement)
    File.write(candidate, modified)
    _out, _err, result = Open3.capture3(RbConfig.ruby, validator, candidate)
    check(!result.success?, "unsafe change accepted: #{description}")
  end
end
puts "STUDIO_QA_COMMISSION_NEGATIVE_TESTS_PASS"
