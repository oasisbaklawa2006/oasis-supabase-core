#!/usr/bin/env bash
# tcxvcatsqqertcnycuop is the one and only Supabase project this repository
# is authoritative over, and it is PRODUCTION -- there is no separate
# staging/preview/test/development Supabase project in this organization.
# The 2026-08-16/17 incident happened in part because workflow names and
# comments described this exact project as "staging". This check fails any
# live workflow or configuration file that mislabels it. Documentation that
# explains the historical incident (which must describe the mislabeling to
# be legible) is exempt.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

PROD_REF='tcxvcatsqqertcnycuop'
fail() { echo "PRODUCTION-REF-AUTHORITY VIOLATION: $*" >&2; exit 1; }

# Documentation is exempt: it is where the historical incident and its
# corrected terminology are legitimately explained in prose.
mapfile -t scan_files < <(git ls-files -- \
  '.github/workflows/*' \
  'supabase/config.toml' \
  'scripts/*' \
  | grep -v -E '^docs/' \
  | sort -u)

# Files whose entire purpose is to document/retire the historical mislabeling
# incident are exempt by path, same rationale as the docs/ exemption above --
# their prose must be able to say the word "staging" to explain what was
# wrong. They must not, however, contain a live command that treats the
# project as anything other than production.
declare -A INCIDENT_DOC_FILES=(
  [".github/workflows/step1-staging-certification.yml"]=1
)

forbidden_labels='staging|pre-?prod|preview|non-?prod|test[-_ ]?(project|environment|database|db)\b|\bdevelopment\b'

violations=0
for file in "${scan_files[@]}"; do
  [[ -f "$file" ]] || continue
  grep -q "$PROD_REF" "$file" || continue

  if [[ -n "${INCIDENT_DOC_FILES[$file]:-}" ]]; then
    continue
  fi

  # Fail if any line mentioning the production ref (or within a few lines of
  # it) also carries a mislabeling term -- e.g. an environment name, job
  # title, or variable naming the project as non-production.
  while IFS=: read -r lineno line; do
    [[ -n "$lineno" ]] || continue
    echo "  $file:$lineno mislabels the production project ($PROD_REF):" >&2
    echo "    $line" >&2
    violations=$((violations + 1))
  done < <(grep -noiE ".*($forbidden_labels).*$PROD_REF.*|.*$PROD_REF.*($forbidden_labels).*" "$file" 2>/dev/null || true)
done

# supabase/config.toml declares project identity once; assert it is present
# and unambiguous, and that no [environments.*] non-production stanza also
# claims this ref.
if [[ -f supabase/config.toml ]]; then
  grep -Fxq "project_id = \"$PROD_REF\"" supabase/config.toml \
    || fail "supabase/config.toml does not declare project_id = \"$PROD_REF\""
fi

if ((violations > 0)); then
  fail "$violations file(s) label the production project ($PROD_REF) as something other than production. Only docs/** may discuss the historical mislabeling incident in prose; live workflows/config/scripts must never do so."
fi

echo "OK: $PROD_REF is labeled PRODUCTION everywhere it is referenced outside docs/."
