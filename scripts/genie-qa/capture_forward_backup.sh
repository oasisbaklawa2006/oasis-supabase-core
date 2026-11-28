#!/usr/bin/env bash
# Read-only full database logical archive. No plaintext artifact, no restore
# against any hosted database. Archive integrity is not a restore rehearsal.
set -euo pipefail
umask 077
root="$(cd "$(dirname "$0")/../.." && pwd)"
python3 "$root/scripts/genie-qa/verify_qa_target.py" >/dev/null
[[ "$GENIE_QA_RUN_MODE" == preflight-forward || "$GENIE_QA_RUN_MODE" == apply-forward ]]
[[ "$PGSSLMODE" == verify-full && -s "$PGSSLROOTCERT" ]]
[[ "${#GENIE_QA_BACKUP_PASSPHRASE}" -ge 32 && "$GENIE_QA_BACKUP_PASSPHRASE" != *$'\n'* && "$GENIE_QA_BACKUP_PASSPHRASE" != *$'\r'* ]] || {
  echo "::error::QA_BACKUP_KEY_MISSING_OR_INVALID"; exit 1;
}
export PATH="/usr/lib/postgresql/17/bin:$PATH"
export PGCONNECT_TIMEOUT=10
export PGOPTIONS='-c default_transaction_read_only=on -c statement_timeout=300000'
for command in pg_dump pg_restore pg_dumpall gpg tar sha256sum; do command -v "$command" >/dev/null; done
version="$(psql "$GENIE_QA_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c 'show server_version_num' 2>/dev/null)"
[[ "$version" =~ ^17[0-9]{4}$ ]] && [[ "$(pg_dump --version)" =~ PostgreSQL\)\ 17\. ]] || { echo "::error::QA_BACKUP_CLIENT_VERSION_MISMATCH"; exit 1; }
safe="$(psql "$GENIE_QA_DATABASE_URL" -X -qAt -v ON_ERROR_STOP=1 -c "select not exists(select 1 from pg_extension where extname in ('pg_cron','pg_net','http','dblink')) and to_regclass('cron.job') is null" 2>/dev/null)"
[[ "$safe" == t ]] || { echo "::error::QA_BACKUP_EGRESS_GUARD"; exit 1; }
out="$RUNNER_TEMP/genie-qa-encrypted-backup"
[[ ! -e "$out" ]]
mkdir -m 700 "$out"
tmp="$(mktemp -d "$RUNNER_TEMP/qa-backup-private.XXXXXX")"
trap 'rm -rf -- "$tmp"' EXIT
export GNUPGHOME="$tmp/gnupg"
mkdir -m 700 "$GNUPGHOME"
baseline="$RUNNER_TEMP/qa-preservation-before.json"
[[ ! -e "$baseline" ]]
bash "$root/scripts/genie-qa/forward_preservation.sh" "$baseline"
cp "$baseline" "$tmp/preservation.json"
cp "$RUNNER_TEMP/qa-recorded-versions.txt" "$tmp/ledger.txt"
printf '%s\n' "$GENIE_QA_EXPECTED_SHA" >"$tmp/source-sha.txt"
if ! pg_dump --format=custom --no-password --file="$tmp/database.dump" --dbname="$GENIE_QA_DATABASE_URL" >"$tmp/dump.log" 2>&1 ||
   ! pg_dumpall --roles-only --no-role-passwords --no-password --file="$tmp/roles.sql" --dbname="$GENIE_QA_DATABASE_URL" >"$tmp/roles.log" 2>&1; then
  echo "::error::QA_LOGICAL_BACKUP_FAILED (private logs withheld)"; exit 1
fi
[[ -s "$tmp/database.dump" && -s "$tmp/roles.sql" ]]
pg_restore --list "$tmp/database.dump" >"$tmp/toc.txt" 2>"$tmp/restore.log"
for item in 'auth users' 'auth identities' 'auth sessions' 'auth refresh_tokens' 'public b2b_applications' 'public profiles' 'public companies' 'public customer_order_drafts' 'public customer_order_draft_lines' 'public customer_order_draft_audit_log' 'public products' 'public product_pricing_rules' 'public product_moq_rules' 'supabase_migrations schema_migrations'; do
  grep -Eq "TABLE DATA $item " "$tmp/toc.txt" || { echo "::error::QA_LOGICAL_BACKUP_REQUIRED_TABLE_MISSING"; exit 1; }
done
# Decode every archive entry, without executing SQL or connecting a restore target.
pg_restore --file=/dev/null "$tmp/database.dump" >"$tmp/decode.log" 2>&1 || { echo "::error::QA_LOGICAL_ARCHIVE_DECODE_FAILED"; exit 1; }
bash "$root/scripts/genie-qa/forward_preservation.sh" "$baseline"
(cd "$tmp"; sha256sum database.dump roles.sql preservation.json ledger.txt source-sha.txt > manifest.sha256
 tar -cf recovery.tar database.dump roles.sql preservation.json ledger.txt source-sha.txt manifest.sha256 toc.txt)
gpg --batch --no-symkey-cache --pinentry-mode loopback --passphrase-fd 3 --symmetric --cipher-algo AES256 \
 --output "$out/backup.tar.gpg" "$tmp/recovery.tar" 3<<<"$GENIE_QA_BACKUP_PASSPHRASE" >"$tmp/gpg.log" 2>&1
gpg --batch --no-symkey-cache --pinentry-mode loopback --passphrase-fd 3 --decrypt \
 --output "$tmp/readback.tar" "$out/backup.tar.gpg" 3<<<"$GENIE_QA_BACKUP_PASSPHRASE" >"$tmp/gpg-read.log" 2>&1
cmp -s "$tmp/recovery.tar" "$tmp/readback.tar" || { echo "::error::QA_ENCRYPTED_ARCHIVE_ROUNDTRIP_FAILED"; exit 1; }
(cd "$out"; sha256sum backup.tar.gpg > backup.tar.gpg.sha256)
echo 'QA_LOGICAL_ARCHIVE_ENCRYPTED_AND_DECODE_VERIFIED; no hosted restore performed'
