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
}
cases.each do |name, mutation|
  abort "Mutation fixture unchanged: #{name}" if mutation == source
  abort "Unsafe mutation passed: #{name}" if run_checker(checker, mutation)
end
puts "Seven negative release-governance cases failed closed."
