#!/usr/bin/env bash
# Regression contract for scripts/publish-core-merge-governance-check.sh.
set -euo pipefail

repo_root="$(git rev-parse --show-toplevel)"
script="$repo_root/scripts/publish-core-merge-governance-check.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"

fail() {
  echo "PUBLISH CORE MERGE GOVERNANCE CHECK REGRESSION: $*" >&2
  exit 1
}

mock_curl_capture() {
  cat >"$tmp/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
# Capture the POSTed JSON body (the argument right after -d) for inspection.
prev=""
for arg in "$@"; do
  if [[ "$prev" == "-d" ]]; then
    printf '%s' "$arg" > "$MOCK_CAPTURED_BODY"
  fi
  prev="$arg"
done
printf '{"id": 424242, "conclusion": "%s", "head_sha": "%s"}' \
  "$MOCK_RESPONSE_CONCLUSION" "$MOCK_RESPONSE_HEAD_SHA"
CURL
  chmod +x "$tmp/bin/curl"
}

# 1. Missing required inputs fail closed.
if HEAD_SHA="" CONCLUSION=success GH_TOKEN=t GITHUB_REPOSITORY=o/r bash "$script" >/dev/null 2>"$tmp/err1"; then
  fail 'missing HEAD_SHA must fail'
fi
grep -Fq 'HEAD_SHA is required' "$tmp/err1" || fail 'missing HEAD_SHA must report its cause'

if HEAD_SHA=deadbeef CONCLUSION="" GH_TOKEN=t GITHUB_REPOSITORY=o/r bash "$script" >/dev/null 2>"$tmp/err2"; then
  fail 'missing CONCLUSION must fail'
fi
grep -Fq 'CONCLUSION is required' "$tmp/err2" || fail 'missing CONCLUSION must report its cause'

unset GH_TOKEN GITHUB_TOKEN || true
if HEAD_SHA=deadbeef CONCLUSION=success GITHUB_REPOSITORY=o/r bash "$script" >/dev/null 2>"$tmp/err3"; then
  fail 'missing GH_TOKEN must fail'
fi
grep -Fq 'GH_TOKEN is required' "$tmp/err3" || fail 'missing GH_TOKEN must report its cause'

# 2. Unrecognized conclusion value fails closed (never silently coerced).
if HEAD_SHA=deadbeef CONCLUSION=bogus GH_TOKEN=t GITHUB_REPOSITORY=o/r bash "$script" >/dev/null 2>"$tmp/err4"; then
  fail 'unrecognized conclusion must fail'
fi
grep -Fq 'unrecognized job conclusion' "$tmp/err4" || fail 'unrecognized conclusion must report its cause'

# 3. A valid call posts the exact head_sha/conclusion/name and succeeds for each allowed conclusion.
for conclusion in success failure cancelled; do
  mock_curl_capture
  MOCK_CAPTURED_BODY="$tmp/body-${conclusion}.json" \
    MOCK_RESPONSE_CONCLUSION="$conclusion" \
    MOCK_RESPONSE_HEAD_SHA="deadbeef" \
    PATH="$tmp/bin:$PATH" \
    HEAD_SHA=deadbeef CONCLUSION="$conclusion" GH_TOKEN=t GITHUB_REPOSITORY=o/r \
    bash "$script" >"$tmp/out-${conclusion}.txt" 2>&1 \
    || { cat "$tmp/out-${conclusion}.txt" >&2; fail "valid ${conclusion} call must succeed"; }

  grep -Fq "\"head_sha\": \"deadbeef\"" "$tmp/body-${conclusion}.json" \
    || fail "${conclusion} call must post the given head_sha"
  grep -Fq "\"conclusion\": \"${conclusion}\"" "$tmp/body-${conclusion}.json" \
    || fail "${conclusion} call must post the given conclusion"
  grep -Fq '"name": "Core merge governance validation"' "$tmp/body-${conclusion}.json" \
    || fail "${conclusion} call must post the default check name"
  grep -Fq '"status": "completed"' "$tmp/body-${conclusion}.json" \
    || fail "${conclusion} call must post status=completed"
  grep -Fq "Published check run 424242" "$tmp/out-${conclusion}.txt" \
    || fail "${conclusion} call must confirm the published check id"
done

# 4. A custom CHECK_NAME overrides the default.
mock_curl_capture
MOCK_CAPTURED_BODY="$tmp/body-custom.json" \
  MOCK_RESPONSE_CONCLUSION="success" \
  MOCK_RESPONSE_HEAD_SHA="deadbeef" \
  PATH="$tmp/bin:$PATH" \
  HEAD_SHA=deadbeef CONCLUSION=success CHECK_NAME="Custom Check" GH_TOKEN=t GITHUB_REPOSITORY=o/r \
  bash "$script" >/dev/null
grep -Fq '"name": "Custom Check"' "$tmp/body-custom.json" || fail 'CHECK_NAME override must be honored'

echo "Publish Core Merge Governance check regression verified."
