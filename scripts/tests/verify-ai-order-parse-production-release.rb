#!/usr/bin/env ruby
require "open3"
require "tempfile"
path = ".github/workflows/buyer-genie-ai-order-parse-production-release.yml"
source = File.read(path)
checker = "scripts/check-ai-order-parse-production-release.rb"
def run_checker(checker, source)
  Tempfile.create(["ai-order-parse-release", ".yml"]) do |file|
    file.write(source)
    file.flush
    _, _, status = Open3.capture3("ruby", checker, file.path)
    return status.success?
  end
end
abort "Valid release workflow rejected" unless run_checker(checker, source)
deploy = 'supabase functions deploy ai-order-parse --project-ref "$PROJECT_REF" --use-api'
cases = {
  "disjunction bypass" => source.sub(" && inputs.rollback_approved == true", " || inputs.rollback_approved == true"),
  "missing preview evidence gate" => source.sub(" && inputs.preview_uat_approved == true", ""),
  "nonfatal baseline" => source.sub("      - name: Verify pinned live v5 identity without displaying secrets\n", "      - name: Verify pinned live v5 identity without displaying secrets\n        continue-on-error: true\n"),
  "extra deploy function" => source.sub(deploy, 'supabase functions deploy ai-order-parse whatsapp-webhook --project-ref "$PROJECT_REF" --use-api'),
  "extra deploy flag" => source.sub(deploy, deploy + " --no-verify-jwt"),
  "broad deploy" => source.sub(deploy, 'supabase functions deploy --project-ref "$PROJECT_REF" --use-api'),
  "missing live redownload pin" => source.sub(" > live-after-download.json", " > live-stale.json"),
  "omitted branch precheck" => source.sub('test "$GITHUB_REF" = refs/heads/main', 'test "$GITHUB_REF" != refs/heads/main'),
  "rollback digest mismatch bypass" => source.sub('= "$APPROVED_ROLLBACK_SHA256"', '!= "$APPROVED_ROLLBACK_SHA256"'),
  "wrong reviewed artifact binding" => source.sub('run-id: ${{ inputs.approved_preflight_run_id }}', 'run-id: ${{ github.run_id }}'),
  "skipped gemini presence check before write" => source.sub("          jq -e 'type == \"array\" and any(.[]; .name == \"GEMINI_API_KEY\")' production-secrets-before-write.json >/dev/null \\\n            || { echo '::error::AI_ORDER_PARSE_GEMINI_API_KEY_SECRET_ABSENT'; exit 1; }\n", "          echo bypassed\n"),
  "pinned version changed" => source.sub('EXPECTED_LIVE_VERSION: "5"', 'EXPECTED_LIVE_VERSION: "6"'),
  "pinned bundle changed" => source.sub("4f4c48f94f787cd0fec068a3376fece455449b4dbb9ae427dda97aeade0e0004", "0" * 64),
  "wrong project" => source.sub("PROJECT_REF: tcxvcatsqqertcnycuop", "PROJECT_REF: skhpmltfjgqitntkmclb"),
  "write permission" => source.sub("permissions:\n  contents: read\n  actions: read", "permissions:\n  contents: write\n  actions: read"),
  "secret mutation command" => source.sub(deploy, 'supabase secrets set GEMINI_API_KEY=untrusted'),
  "deploy job loses production environment" => source.sub("    environment: supabase-production\n", "    environment: supabase-production-readonly\n"),
}
cases.each do |name, mutation|
  abort "Mutation fixture unchanged: #{name}" if mutation == source
  abort "Unsafe mutation passed: #{name}" if run_checker(checker, mutation)
end
puts "#{cases.length} negative release-governance cases failed closed."
