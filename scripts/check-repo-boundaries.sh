#!/usr/bin/env bash
# Repo ownership boundary check for oasis-supabase-core.
# Fails if this repo absorbs frontend application ownership (routes, pages,
# components, build tooling) that belongs to Oasis-Baklawa-Central or
# oasis-ai-studio. See docs/repo-ownership-guardrails.md for the ownership
# split this enforces.
#
# Unlike oasis-ai-studio's boundary script, this one does not need a base-ref
# diff: this repo has no legitimate frontend content at all, past or present,
# so every check here is a plain "does this exist / does this file contain
# this string" scan of the current working tree — there is no "new vs.
# pre-existing legacy" distinction to make.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

violations=0

# ---------------------------------------------------------------------------
# 1. Frontend application paths must never exist in this repo — it is
#    backend-only. A file matching one of these paths/globs is a hard
#    failure regardless of its content; the location alone is the whole
#    frontend-app surface (an App.tsx, a page, a component, a bundler
#    config), so its mere existence is the violation.
# ---------------------------------------------------------------------------
shopt -s nullglob globstar

FRONTEND_FILE_GLOBS=(
  "src/App.tsx"
  "src/main.tsx"
  "src/pages/**"
  "src/components/**"
  "app/**"
  "pages/**"
  "components/**"
  "public/index.html"
  "index.html"
  "vite.config.*"
  "next.config.*"
  "tailwind.config.*"
  "postcss.config.*"
)

for pattern in "${FRONTEND_FILE_GLOBS[@]}"; do
  matches=()
  for f in $pattern; do
    [ -f "$f" ] && matches+=("$f")
  done
  if [ "${#matches[@]}" -gt 0 ]; then
    echo "BOUNDARY VIOLATION: frontend application path \"$pattern\" found — frontend ownership belongs to Oasis-Baklawa-Central or oasis-ai-studio, not oasis-supabase-core:"
    printf '  %s\n' "${matches[@]}"
    violations=$((violations + 1))
  fi
done

shopt -u nullglob globstar

# ---------------------------------------------------------------------------
# 2. A package.json declaring a frontend-framework dependency is a hard
#    failure. This repo intentionally has no package.json today (nothing to
#    build or bundle here) — if one is ever introduced, it must not signal a
#    frontend app.
# ---------------------------------------------------------------------------
FRONTEND_PACKAGE_SIGNALS=(
  "vite"
  "react"
  "react-dom"
  "@vitejs/react"
  "next"
  "lucide-react"
  "shadcn"
)

if [ -f "package.json" ]; then
  for signal in "${FRONTEND_PACKAGE_SIGNALS[@]}"; do
    if grep -F -q -- "\"${signal}\"" package.json 2>/dev/null; then
      echo "BOUNDARY VIOLATION: package.json declares frontend-framework dependency \"${signal}\" — this repo is backend-only."
      violations=$((violations + 1))
    fi
  done
fi

# ---------------------------------------------------------------------------
# 3. Clear frontend route/component ownership strings must never appear in
#    active (non-doc) code. `.ai-intent/` and `docs/` are excluded on
#    purpose: they document both frontend repos by name (routes, component
#    names, screen registry) — that is their whole job, and scanning them
#    for the same strings this check blocks in real code would false-
#    positive on every legitimate reference. `.git/`, `node_modules/`,
#    `dist/`, `build/`, and `package-lock.json` are excluded as noise/
#    generated content, never hand-written implementation.
# ---------------------------------------------------------------------------
CONTENT_PATTERNS=(
  "BrowserRouter"
  "createBrowserRouter"
  "Route path"
  "AdminLayout"
  "AdminProducts"
  "AdminOrders"
  "AdminFinance"
  "AdminPackingDispatch"
  "DispatchManagement"
  "InventoryCommandCenter"
  "FinanceGovernanceBoard"
  "Catalogue Product AI Studio"
  "Content Draft Studio"
  "Media / Hero Image Prompt Studio"
  "Packaging + Variant"
  "Export / Copy Bundle"
)

GREP_EXCLUDES=(
  --exclude-dir=.git
  --exclude-dir=.ai-intent
  --exclude-dir=docs
  --exclude-dir=node_modules
  --exclude-dir=dist
  --exclude-dir=build
  --exclude=package-lock.json
  # This script's own CONTENT_PATTERNS list necessarily contains every
  # forbidden string verbatim — without this exclude it would always fail
  # against itself.
  --exclude=check-repo-boundaries.sh
)

for pattern in "${CONTENT_PATTERNS[@]}"; do
  matches="$(grep -rIl "${GREP_EXCLUDES[@]}" --fixed-strings -- "$pattern" . 2>/dev/null | sed 's|^\./||' || true)"
  if [ -n "$matches" ]; then
    echo "BOUNDARY VIOLATION: frontend ownership string \"$pattern\" found in active code — belongs to Central or oasis-ai-studio frontend, not oasis-supabase-core:"
    echo "$matches" | sed 's/^/  /'
    violations=$((violations + 1))
  fi
done

# ---------------------------------------------------------------------------
# Explicitly NOT flagged (correct ownership for this repo, never scanned as
# a violation): supabase/migrations/**, supabase/functions/** (including
# supabase/functions/_shared/**), supabase/config.toml. Backend TypeScript
# under supabase/functions is implementation this repo is supposed to own —
# none of the checks above touch it except the content-pattern scan, and
# none of CONTENT_PATTERNS are legitimate substrings of backend function
# code, so it passes through unaffected.
# ---------------------------------------------------------------------------

if [ "$violations" -gt 0 ]; then
  echo ""
  echo "Repo ownership boundary check FAILED ($violations violation(s))."
  echo "See docs/repo-ownership-guardrails.md."
  exit 1
fi

echo "Repo ownership boundary check passed — no frontend application ownership found in oasis-supabase-core."
