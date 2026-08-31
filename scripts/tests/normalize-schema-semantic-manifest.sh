#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
normalizer="$repo_root/scripts/normalize-schema-semantic-manifest.py"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/local" <<'EOF'
{"kind":"function","key":"public.f()","value":{"definition":"CREATE FUNCTION public.f() RETURNS text AS $function$\n-- formatting only\nBEGIN\n  RETURN 'a  b';\nEND;\n$function$ LANGUAGE plpgsql;","security_definer":true}}
{"kind":"relation_grant","key":"public.t:authenticated:SELECT","value":{"grantable":false}}
{"kind":"policy","key":"public.t:p","value":{"command":"SELECT","roles":["authenticated"],"using":"true"}}
EOF
cat > "$tmp/remote" <<'EOF'
{"kind":"function","key":"public.f()","value":{"definition":"CREATE FUNCTION public.f() RETURNS text AS $function$ BEGIN RETURN 'a  b'; END; $function$ LANGUAGE plpgsql;","security_definer":true}}
{"kind":"default_acl","key":"postgres:public:r:authenticated:SELECT","value":{"grantable":false}}
{"kind":"policy","key":"public.t:p","value":{"command":"SELECT","roles":["authenticated"],"using":"true"}}
EOF

python3 "$normalizer" "$tmp/local" "$tmp/remote"
diff -u "$tmp/local" "$tmp/remote"
! grep -q 'relation_grant\|default_acl\|routine_grant' "$tmp/local"

# Quoted business text remains semantic. Whitespace inside a string literal must
# never be normalized away.
cat > "$tmp/local" <<'EOF'
{"kind":"function","key":"public.f()","value":{"definition":"RETURN 'advance due';"}}
EOF
cat > "$tmp/remote" <<'EOF'
{"kind":"function","key":"public.f()","value":{"definition":"RETURN 'advance  due';"}}
EOF
python3 "$normalizer" "$tmp/local" "$tmp/remote"
if diff -q "$tmp/local" "$tmp/remote" >/dev/null; then
  echo 'quoted literal drift was incorrectly normalized away' >&2
  exit 1
fi

echo 'semantic manifest normalization regression: PASS'
