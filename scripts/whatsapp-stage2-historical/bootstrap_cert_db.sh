#!/usr/bin/env bash
# Bootstrap loopback Core DB on :54322 when `supabase start` Realtime init fails.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
CONTAINER="${WA_CERT_PG_CONTAINER:-wa-cert-pg}"
IMAGE="${WA_CERT_PG_IMAGE:-supabase/postgres:17.6.1.043}"
DB_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

if ! docker ps --format '{{.Names}}' | grep -qx "$CONTAINER"; then
  docker rm -f "$CONTAINER" >/dev/null 2>&1 || true
  docker run --rm -d --name "$CONTAINER" -e POSTGRES_PASSWORD=postgres -p 54322:5432 "$IMAGE"
  sleep 12
fi

PGPASSWORD=postgres psql -h 127.0.0.1 -p 54322 -U supabase_admin -d postgres -v ON_ERROR_STOP=1 <<'SQL'
CREATE OR REPLACE FUNCTION auth.jwt() RETURNS jsonb AS $$
  SELECT coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
$$ LANGUAGE sql STABLE;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS file_size_limit bigint;
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS allowed_mime_types text[];
ALTER TABLE storage.buckets ADD COLUMN IF NOT EXISTS public boolean DEFAULT false;
SQL

supabase migration up --include-all --db-url "$DB_URL"
echo "Cert DB ready at $DB_URL"
