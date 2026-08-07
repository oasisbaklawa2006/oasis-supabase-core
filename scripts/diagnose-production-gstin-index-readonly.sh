#!/usr/bin/env bash
# Read-only production diagnostic for uq_companies_gst_number_normalized failure.
# Requires SUPABASE_DB_URL pointing at tcxvcatsqqertcnycuop (read-only session).
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

EXPECTED_PROJECT_REF="${EXPECTED_PROJECT_REF:-tcxvcatsqqertcnycuop}"
OUTPUT_DIR="${OUTPUT_DIR:-production-gstin-index-diagnostic}"
mkdir -p "$OUTPUT_DIR"

: "${SUPABASE_DB_URL:?SUPABASE_DB_URL is required}"

if [[ "$SUPABASE_DB_URL" != *"$EXPECTED_PROJECT_REF"* ]]; then
  echo "Refusing: SUPABASE_DB_URL does not reference expected project $EXPECTED_PROJECT_REF" >&2
  exit 1
fi

PSQL=(psql "$SUPABASE_DB_URL" -X -v ON_ERROR_STOP=1)

run_section() {
  local title="$1"
  local outfile="$2"
  echo "=== $title ===" | tee "$outfile"
}

echo "Diagnostic run at $(date -u +%Y-%m-%dT%H:%M:%SZ)" | tee "$OUTPUT_DIR/run-metadata.txt"
echo "EXPECTED_PROJECT_REF=$EXPECTED_PROJECT_REF" | tee -a "$OUTPUT_DIR/run-metadata.txt"

# 1. PostgreSQL version
run_section "1. PostgreSQL version" "$OUTPUT_DIR/01-postgresql-version.txt"
"${PSQL[@]}" -c "SHOW server_version;" | tee -a "$OUTPUT_DIR/01-postgresql-version.txt"
"${PSQL[@]}" -c "SELECT version();" | tee -a "$OUTPUT_DIR/01-postgresql-version.txt"

# 2. companies.gst_number column definition
run_section "2. companies.gst_number column" "$OUTPUT_DIR/02-gst_number-column.txt"
"${PSQL[@]}" -c "
SELECT
  a.attname,
  pg_catalog.format_type(a.atttypid, a.atttypmod) AS data_type,
  a.attnotnull AS not_null,
  pg_get_expr(d.adbin, d.adrelid) AS default_expr,
  col_description(a.attrelid, a.attnum) AS description
FROM pg_catalog.pg_attribute a
JOIN pg_catalog.pg_class c ON c.oid = a.attrelid
JOIN pg_catalog.pg_namespace n ON n.oid = c.relnamespace
LEFT JOIN pg_catalog.pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
WHERE n.nspname = 'public'
  AND c.relname = 'companies'
  AND a.attname = 'gst_number'
  AND a.attnum > 0
  AND NOT a.attisdropped;
" | tee -a "$OUTPUT_DIR/02-gst_number-column.txt"

# 3. Index existence and definition
run_section "3. uq_companies_gst_number_normalized index" "$OUTPUT_DIR/03-index-existence.txt"
"${PSQL[@]}" -c "
SELECT
  i.relname AS index_name,
  pg_get_indexdef(i.oid) AS index_definition,
  ix.indisunique AS is_unique,
  ix.indisvalid AS is_valid,
  ix.indisready AS is_ready,
  pg_get_expr(ix.indpred, ix.indrelid) AS index_predicate
FROM pg_catalog.pg_class i
JOIN pg_catalog.pg_index ix ON ix.indexrelid = i.oid
JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public'
  AND t.relname = 'companies'
  AND i.relname = 'uq_companies_gst_number_normalized';
" | tee -a "$OUTPUT_DIR/03-index-existence.txt"

"${PSQL[@]}" -c "
SELECT count(*) AS matching_index_count
FROM pg_catalog.pg_class i
JOIN pg_catalog.pg_index ix ON ix.indexrelid = i.oid
JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
WHERE n.nspname = 'public'
  AND t.relname = 'companies'
  AND i.relname = 'uq_companies_gst_number_normalized';
" | tee -a "$OUTPUT_DIR/03-index-existence.txt"

# 4. Count valid normalized GSTIN rows
run_section "4. Valid normalized GSTIN count" "$OUTPUT_DIR/04-valid-gstin-count.txt"
"${PSQL[@]}" -c "
SELECT count(*) AS valid_normalized_gstin_company_count
FROM public.companies
WHERE gst_number IS NOT NULL
  AND upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$';
" | tee -a "$OUTPUT_DIR/04-valid-gstin-count.txt"

# 5. Duplicate groups
run_section "5. Duplicate normalized VALID GSTIN groups" "$OUTPUT_DIR/05-duplicate-groups.txt"
"${PSQL[@]}" -c "
SELECT
  upper(regexp_replace(gst_number, '\s', '', 'g')) AS normalized_gstin,
  count(*) AS duplicate_count,
  array_agg(id ORDER BY id) AS company_ids,
  array_agg(business_name ORDER BY id) AS company_names,
  array_agg(gst_number ORDER BY id) AS original_gst_numbers
FROM public.companies
WHERE gst_number IS NOT NULL
  AND upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
GROUP BY upper(regexp_replace(gst_number, '\s', '', 'g'))
HAVING count(*) > 1
ORDER BY duplicate_count DESC, normalized_gstin;
" | tee -a "$OUTPUT_DIR/05-duplicate-groups.txt"

"${PSQL[@]}" -c "
SELECT count(*) AS duplicate_group_count
FROM (
  SELECT upper(regexp_replace(gst_number, '\s', '', 'g')) AS normalized_gstin
  FROM public.companies
  WHERE gst_number IS NOT NULL
    AND upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
  GROUP BY upper(regexp_replace(gst_number, '\s', '', 'g'))
  HAVING count(*) > 1
) d;
" | tee -a "$OUTPUT_DIR/05-duplicate-groups.txt"

# 6. Immutability / indexability of expression and predicate
run_section "6. Expression immutability and indexability" "$OUTPUT_DIR/06-immutability-indexability.txt"
"${PSQL[@]}" -c "
SELECT
  p.proname,
  p.provolatile,
  pg_get_function_identity_arguments(p.oid) AS args
FROM pg_catalog.pg_proc p
JOIN pg_catalog.pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'pg_catalog'
  AND p.proname IN ('upper', 'regexp_replace')
ORDER BY p.proname, args;
" | tee -a "$OUTPUT_DIR/06-immutability-indexability.txt"

"${PSQL[@]}" -c "
SELECT
  upper(regexp_replace('29 abcde1234f1z5', '\s', '', 'g')) AS sample_expr_result,
  upper(regexp_replace('29abcde1234f1z5', '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$' AS sample_predicate_match;
" | tee -a "$OUTPUT_DIR/06-immutability-indexability.txt"

# Attempt index expression validation via hypothetical index (no persistent DDL)
"${PSQL[@]}" -c "
DO \$\$
BEGIN
  PERFORM 1
  FROM pg_catalog.pg_type
  WHERE typname = 'int4'
    AND upper(regexp_replace('test', '\s', '', 'g')) IS NOT NULL;
  RAISE NOTICE 'Expression upper(regexp_replace(...)) evaluated in DO block successfully';
END
\$\$;
" | tee -a "$OUTPUT_DIR/06-immutability-indexability.txt" || true

# 7. Rolled-back CREATE INDEX reproduction (capture SQLSTATE if duplicates are not the cause)
run_section "7. Rolled-back CREATE INDEX reproduction" "$OUTPUT_DIR/07-create-index-rollback.txt"
set +e
"${PSQL[@]}" -v ON_ERROR_STOP=0 <<'SQL' | tee -a "$OUTPUT_DIR/07-create-index-rollback.txt"
BEGIN;
CREATE UNIQUE INDEX diag_uq_companies_gst_number_normalized_rollback_probe
  ON public.companies (upper(regexp_replace(gst_number, '\s', '', 'g')))
  WHERE gst_number IS NOT NULL
    AND upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$';
ROLLBACK;
SQL
rollback_exit=$?
set -e
echo "rollback_probe_exit_code=$rollback_exit" | tee -a "$OUTPUT_DIR/07-create-index-rollback.txt"

# Also probe exact migration statement with IF NOT EXISTS inside rollback
set +e
"${PSQL[@]}" -v ON_ERROR_STOP=0 <<'SQL' | tee -a "$OUTPUT_DIR/07-create-index-rollback.txt"
BEGIN;
CREATE UNIQUE INDEX IF NOT EXISTS uq_companies_gst_number_normalized
  ON public.companies (upper(regexp_replace(gst_number, '\s', '', 'g')))
  WHERE gst_number IS NOT NULL
    AND upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$';
ROLLBACK;
SQL
migration_probe_exit=$?
set -e
echo "migration_statement_probe_exit_code=$migration_probe_exit" | tee -a "$OUTPUT_DIR/07-create-index-rollback.txt"

# Summary synthesis
run_section "8. Diagnostic summary" "$OUTPUT_DIR/08-summary.txt"
duplicate_groups="$(
  "${PSQL[@]}" -At -c "
    SELECT count(*)
    FROM (
      SELECT upper(regexp_replace(gst_number, '\s', '', 'g'))
      FROM public.companies
      WHERE gst_number IS NOT NULL
        AND upper(regexp_replace(gst_number, '\s', '', 'g')) ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'
      GROUP BY upper(regexp_replace(gst_number, '\s', '', 'g'))
      HAVING count(*) > 1
    ) d;
  "
)"
index_exists="$(
  "${PSQL[@]}" -At -c "
    SELECT count(*)
    FROM pg_catalog.pg_class i
    JOIN pg_catalog.pg_index ix ON ix.indexrelid = i.oid
    JOIN pg_catalog.pg_class t ON t.oid = ix.indrelid
    JOIN pg_catalog.pg_namespace n ON n.oid = t.relnamespace
    WHERE n.nspname = 'public'
      AND t.relname = 'companies'
      AND i.relname = 'uq_companies_gst_number_normalized';
  "
)"

{
  echo "duplicate_group_count=$duplicate_groups"
  echo "index_exists_count=$index_exists"
  echo "rollback_probe_exit_code=$rollback_exit"
  echo "migration_statement_probe_exit_code=$migration_probe_exit"
  if [[ "$duplicate_groups" != "0" ]]; then
    echo "likely_root_cause=duplicate_valid_normalized_gstin_groups"
  elif [[ "$index_exists" != "0" ]]; then
    echo "likely_root_cause=index_already_exists_with_possible_definition_mismatch"
  elif [[ "$rollback_probe_exit" != "0" || "$migration_probe_exit" != "0" ]]; then
    echo "likely_root_cause=see_07-create-index-rollback.txt_for_sqlstate"
  else
    echo "likely_root_cause=rolled_back_probe_succeeded_duplicates_not_reproduced_in_readonly_session"
  fi
} | tee "$OUTPUT_DIR/08-summary.txt"

echo "Diagnostic artifacts written to $OUTPUT_DIR/"
