#!/usr/bin/env ruby
require "open3"
require "tempfile"
path = ".github/workflows/catalogue-ai-copy-production-release.yml"
source = File.read(path)
checker = "scripts/check-catalogue-ai-copy-production-release.rb"
def run_checker(checker, source)
  Tempfile.create(["catalogue-release", ".yml"]) do |file|
    file.write(source)
    file.flush
    _, _, status = Open3.capture3("ruby", checker, file.path)
    return status.success?
  end
end
abort "Valid release workflow rejected" unless run_checker(checker, source)
cases = {
  "disjunction bypass" => source.sub(" && inputs.rollback_approved == true", " || inputs.rollback_approved == true"),
  "nonfatal baseline" => source.sub("      - name: Verify pinned live v44 identity without displaying secrets\n", "      - name: Verify pinned live v44 identity without displaying secrets\n        continue-on-error: true\n"),
  "skipped baseline" => source.sub("      - name: Verify pinned live v44 identity without displaying secrets\n", "      - name: Verify pinned live v44 identity without displaying secrets\n        if: false\n"),
  "extra deploy function" => source.sub('supabase functions deploy catalogue-ai-copy --project-ref "$PROJECT_REF" --use-api', 'supabase functions deploy catalogue-ai-copy whatsapp-webhook --project-ref "$PROJECT_REF" --use-api'),
  "extra deploy flag" => source.sub('supabase functions deploy catalogue-ai-copy --project-ref "$PROJECT_REF" --use-api', 'supabase functions deploy catalogue-ai-copy --project-ref "$PROJECT_REF" --use-api --no-verify-jwt'),
  "missing live redownload pin" => source.sub(" > live-after-download.json", " > live-stale.json"),
  "omitted branch precheck" => source.sub('test "$GITHUB_REF" = refs/heads/main', 'test "$GITHUB_REF" != refs/heads/main'),
  "rollback digest mismatch bypass" => source.sub('= "$APPROVED_ROLLBACK_SHA256"', '!= "$APPROVED_ROLLBACK_SHA256"'),
  "wrong reviewed artifact binding" => source.sub('run-id: ${{ inputs.approved_preflight_run_id }}', 'run-id: ${{ github.run_id }}'),
  "skipped no-spend check" => source.sub('python3 scripts/verify-catalogue-ai-zero-spend-secrets.py production-secrets-before-write.json', 'echo bypassed'),
  "conditional recovery bypass" => source.sub("inputs.verify_existing == true && inputs.deploy == false", "inputs.verify_existing == true || inputs.deploy == false"),
  "recovery accepts preflight-only run" => source.sub('(.steps | any(.name == "Deploy catalogue-ai-copy ONLY; preserve JWT and existing secrets" and .conclusion == "success"))', '(.steps | any(.name == "Deploy catalogue-ai-copy ONLY; preserve JWT and existing secrets" and .conclusion == "skipped"))'),
  "recovery original job query removed" => source.sub('/actions/runs/$SOURCE_DEPLOYMENT_RUN_ID/jobs?per_page=100', '/actions/runs/$SOURCE_DEPLOYMENT_RUN_ID/artifacts?per_page=100'),
  "secret mutation command" => source.sub('supabase functions deploy catalogue-ai-copy --project-ref "$PROJECT_REF" --use-api', 'supabase secrets set OPENAI_API_KEY=untrusted && supabase functions deploy catalogue-ai-copy --project-ref "$PROJECT_REF" --use-api'),

}
cases.each do |name, mutation|
  abort "Mutation fixture unchanged: #{name}" if mutation == source
  abort "Unsafe mutation passed: #{name}" if run_checker(checker, mutation)
end
puts "#{cases.length} negative release-governance cases failed closed."
