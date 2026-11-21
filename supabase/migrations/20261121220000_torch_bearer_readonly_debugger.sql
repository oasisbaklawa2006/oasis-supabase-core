-- WO-TB-01 — Torch Bearer read-only debugger surface (Core).
-- Forward-only, additive. Creates ONLY: private schema torch_bearer, four aggregate
-- views, and the NOLOGIN role torch_bearer_reader.
--
-- Security model
--   * Every view is security_invoker = false (runs as its owner), so the reader role
--     needs ZERO grants on public.* / supabase_migrations.* application tables.
--   * Views are aggregate-only: counts, allowlisted reason codes, timestamps, version
--     strings. No message bodies, recipient identifiers, provider payloads, secrets,
--     tokens, DSNs or statement bodies are selected anywhere.
--   * No credentials and no LOGIN role live in Git. The QA LOGIN role is created
--     out-of-band (see PR description). Production LOGIN is a separate governed step.
--   * Legacy public-schema grants are intentionally NOT modified here (Phase 3 finding).
--   * torch_bearer must never be added to the PostgREST exposed-schemas list.

SET LOCAL lock_timeout = '5s';
SET LOCAL statement_timeout = '60s';

-- ---------------------------------------------------------------------------
-- Schema + role
-- ---------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS torch_bearer;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'torch_bearer_reader') THEN
    CREATE ROLE torch_bearer_reader
      NOLOGIN
      NOSUPERUSER
      NOCREATEDB
      NOCREATEROLE
      NOREPLICATION
      NOBYPASSRLS
      NOINHERIT;
  END IF;
END
$$;

-- Role-level defaults apply to any future session that logs in as (or is derived from)
-- this role; harmless while NOLOGIN.
ALTER ROLE torch_bearer_reader SET default_transaction_read_only = on;
ALTER ROLE torch_bearer_reader SET statement_timeout = '5s';
ALTER ROLE torch_bearer_reader SET search_path = pg_catalog;

-- Allow pgTAP SET ROLE / replay impersonation by the migration owner. The reader
-- retains zero parent-role memberships (same pattern as oasis_drift_watch_ro).
GRANT torch_bearer_reader TO postgres;

-- ---------------------------------------------------------------------------
-- View 1: WhatsApp outbox summary (counts only; no bodies, recipients, payloads)
--   dimension = status | reason_code | callback | event_type
--   reason_code / event_type are allowlisted structurally: only UPPER_SNAKE tokens
--   without 5+ digit runs pass; anything else collapses to OTHER_REDACTED.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE VIEW torch_bearer.wa_outbox_summary_v1
WITH (security_invoker = false)
AS
SELECT 'operator_reply_outbox'::text AS source,
       'status'::text AS dimension,
       coalesce(o.status, 'UNKNOWN')::text AS key,
       count(*)::bigint AS row_count,
       min(o.created_at) AS oldest_at,
       max(o.created_at) AS newest_at
  FROM public.whatsapp_operator_reply_outbox o
 GROUP BY 3
UNION ALL
SELECT 'operator_reply_outbox', 'reason_code', c.code, count(*)::bigint,
       min(o.created_at), max(o.created_at)
  FROM public.whatsapp_operator_reply_outbox o
  CROSS JOIN LATERAL (
    SELECT CASE
             WHEN o.last_error_code ~ '^[A-Z][A-Z0-9_]{1,47}$'
              AND o.last_error_code !~ '[0-9]{5,}' THEN o.last_error_code
             ELSE 'OTHER_REDACTED'
           END AS code
  ) c
 WHERE o.last_error_code IS NOT NULL
 GROUP BY 3
UNION ALL
SELECT 'operator_reply_outbox', 'callback', k.key, count(*)::bigint,
       min(k.at), max(k.at)
  FROM (
    SELECT 'ACCEPTED'::text AS key, o.accepted_at AS at
      FROM public.whatsapp_operator_reply_outbox o WHERE o.accepted_at IS NOT NULL
    UNION ALL
    SELECT 'DELIVERED', o.delivered_at
      FROM public.whatsapp_operator_reply_outbox o WHERE o.delivered_at IS NOT NULL
    UNION ALL
    SELECT 'READ', o.read_at
      FROM public.whatsapp_operator_reply_outbox o WHERE o.read_at IS NOT NULL
    UNION ALL
    SELECT 'FAILED_FINAL', o.updated_at
      FROM public.whatsapp_operator_reply_outbox o WHERE o.status = 'FAILED_FINAL'
  ) k
 GROUP BY 3
UNION ALL
SELECT 'operator_reply_events', 'event_type', c.code, count(*)::bigint,
       min(e.created_at), max(e.created_at)
  FROM public.whatsapp_operator_reply_events e
  CROSS JOIN LATERAL (
    SELECT CASE
             WHEN e.event_type ~ '^[A-Z][A-Z0-9_]{1,47}$'
              AND e.event_type !~ '[0-9]{5,}' THEN e.event_type
             ELSE 'OTHER_REDACTED'
           END AS code
  ) c
 GROUP BY 3
UNION ALL
SELECT 'notification_outbox_whatsapp', 'status', coalesce(n.status, 'UNKNOWN')::text,
       count(*)::bigint, min(n.created_at), max(n.created_at)
  FROM public.notification_outbox n
 WHERE n.channel = 'whatsapp'
 GROUP BY 3
UNION ALL
SELECT 'packet_ai_dispatch_jobs', 'status', coalesce(j.state, 'UNKNOWN')::text,
       count(*)::bigint, min(j.created_at), max(j.created_at)
  FROM public.whatsapp_packet_ai_dispatch_jobs j
 GROUP BY 3
UNION ALL
SELECT 'packet_ai_dispatch_jobs', 'reason_code', c.code, count(*)::bigint,
       min(j.created_at), max(j.created_at)
  FROM public.whatsapp_packet_ai_dispatch_jobs j
  CROSS JOIN LATERAL (
    SELECT CASE
             WHEN j.last_error_code ~ '^[A-Z][A-Z0-9_]{1,47}$'
              AND j.last_error_code !~ '[0-9]{5,}' THEN j.last_error_code
             ELSE 'OTHER_REDACTED'
           END AS code
  ) c
 WHERE j.last_error_code IS NOT NULL
 GROUP BY 3;

-- ---------------------------------------------------------------------------
-- Views 2-4 depend on tables/columns that may be absent in a given environment
-- (e.g. supabase_migrations outside the Supabase CLI/platform). They are built from
-- catalog probes so "absent" is reported as ABSENT instead of failing the migration.
-- Every generated view still carries WITH (security_invoker = false).
-- ---------------------------------------------------------------------------
DO $build$
DECLARE
  v_sql text;
  v_parts text[] := ARRAY[]::text[];
  r record;
  v_flag_ok boolean;
  v_seen_ok boolean;
  v_sync_ok boolean;
  v_active_ok boolean;
BEGIN
  ---------------------------------------------------------------------------
  -- View 2: config / policy summary. States: ABSENT, ZERO_ROW, ENABLED,
  -- DISABLED, MIXED, UNKNOWN. Flag columns only; no config values are read.
  ---------------------------------------------------------------------------
  FOR r IN
    SELECT * FROM (VALUES
      ('whatsapp_config',                'public', 'whatsapp_config',                'is_active'),
      ('order_production_evidence_policy','public','order_production_evidence_policy','enforce_packed_ready')
    ) AS t(source_key, sch, tbl, flag_col)
  LOOP
    IF to_regclass(format('%I.%I', r.sch, r.tbl)) IS NULL THEN
      v_parts := v_parts || format(
        $f$SELECT %L::text AS source_key, 'ABSENT'::text AS table_state, 'ABSENT'::text AS state,
                  NULL::bigint AS row_count, NULL::bigint AS enabled_count,
                  NULL::bigint AS disabled_count, NULL::bigint AS unknown_count$f$,
        r.source_key);
      CONTINUE;
    END IF;

    SELECT EXISTS (
      SELECT 1 FROM information_schema.columns c
       WHERE c.table_schema = r.sch AND c.table_name = r.tbl AND c.column_name = r.flag_col
         AND c.data_type = 'boolean'
    ) INTO v_flag_ok;

    IF NOT v_flag_ok THEN
      v_parts := v_parts || format(
        $f$SELECT %L::text AS source_key, 'PRESENT'::text AS table_state, 'UNKNOWN'::text AS state,
                  (SELECT count(*) FROM %I.%I)::bigint AS row_count, NULL::bigint AS enabled_count,
                  NULL::bigint AS disabled_count, NULL::bigint AS unknown_count$f$,
        r.source_key, r.sch, r.tbl);
    ELSE
      v_parts := v_parts || format(
        $f$SELECT %1$L::text AS source_key, 'PRESENT'::text AS table_state,
                  CASE
                    WHEN a.n = 0 THEN 'ZERO_ROW'
                    WHEN a.n_on > 0 AND a.n_off = 0 AND a.n_unk = 0 THEN 'ENABLED'
                    WHEN a.n_off > 0 AND a.n_on = 0 AND a.n_unk = 0 THEN 'DISABLED'
                    WHEN a.n_unk > 0 AND a.n_on = 0 AND a.n_off = 0 THEN 'UNKNOWN'
                    ELSE 'MIXED'
                  END::text AS state,
                  a.n AS row_count, a.n_on AS enabled_count, a.n_off AS disabled_count, a.n_unk AS unknown_count
             FROM (SELECT count(*)::bigint AS n,
                          count(*) FILTER (WHERE %4$I IS TRUE)::bigint AS n_on,
                          count(*) FILTER (WHERE %4$I IS FALSE)::bigint AS n_off,
                          count(*) FILTER (WHERE %4$I IS NULL)::bigint AS n_unk
                     FROM %2$I.%3$I) a$f$,
        r.source_key, r.sch, r.tbl, r.flag_col);
    END IF;
  END LOOP;

  v_sql := 'CREATE OR REPLACE VIEW torch_bearer.config_policy_summary_v1 '
        || 'WITH (security_invoker = false) AS '
        || array_to_string(v_parts, ' UNION ALL ');
  EXECUTE v_sql;

  ---------------------------------------------------------------------------
  -- View 3: migration ledger summary. Version strings only (no name/statements/
  -- created_by/DSN). Single row. state: ABSENT, ZERO_ROW, PRESENT.
  ---------------------------------------------------------------------------
  IF to_regclass('supabase_migrations.schema_migrations') IS NOT NULL
     AND EXISTS (
       SELECT 1 FROM information_schema.columns c
        WHERE c.table_schema = 'supabase_migrations'
          AND c.table_name = 'schema_migrations' AND c.column_name = 'version'
     ) THEN
    v_sql := $v$
      CREATE OR REPLACE VIEW torch_bearer.migration_ledger_summary_v1
      WITH (security_invoker = false) AS
      SELECT CASE WHEN count(m.version) = 0 THEN 'ZERO_ROW' ELSE 'PRESENT' END::text AS ledger_state,
             count(m.version)::bigint AS applied_count,
             min(m.version::text) AS earliest_version,
             max(m.version::text) AS latest_version,
             coalesce(array_agg(m.version::text ORDER BY m.version::text)
                      FILTER (WHERE m.version IS NOT NULL), ARRAY[]::text[]) AS versions
        FROM supabase_migrations.schema_migrations m
    $v$;
  ELSE
    v_sql := $v$
      CREATE OR REPLACE VIEW torch_bearer.migration_ledger_summary_v1
      WITH (security_invoker = false) AS
      SELECT 'ABSENT'::text AS ledger_state,
             NULL::bigint AS applied_count,
             NULL::text AS earliest_version,
             NULL::text AS latest_version,
             NULL::text[] AS versions
    $v$;
  END IF;
  EXECUTE v_sql;

  ---------------------------------------------------------------------------
  -- View 4: device sync summary. last_seen_at and last_successful_sync_at are
  -- reported separately; each is NULL with *_state = 'UNKNOWN' when no source column
  -- or no value exists (never inferred from the other). Aggregates only: no device
  -- ids, labels, tokens or hashes.
  ---------------------------------------------------------------------------
  v_parts := ARRAY[]::text[];
  FOR r IN
    SELECT * FROM (VALUES
      ('display_device_registry_v1', 'public', 'display_device_registry_v1',
         'last_seen_at', 'last_successful_sync_at', 'is_active'),
      ('tv_devices',                 'public', 'tv_devices',
         'last_seen_at', 'last_successful_sync_at', 'is_enabled')
    ) AS t(source_key, sch, tbl, seen_col, sync_col, active_col)
  LOOP
    IF to_regclass(format('%I.%I', r.sch, r.tbl)) IS NULL THEN
      v_parts := v_parts || format(
        $f$SELECT %L::text AS source_key, 'ABSENT'::text AS table_state,
                  NULL::bigint AS device_count, NULL::bigint AS active_count,
                  NULL::timestamptz AS last_seen_at, 'UNKNOWN'::text AS last_seen_state,
                  NULL::timestamptz AS last_successful_sync_at, 'UNKNOWN'::text AS last_sync_state$f$,
        r.source_key);
      CONTINUE;
    END IF;

    SELECT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema = r.sch
             AND c.table_name = r.tbl AND c.column_name = r.seen_col
             AND c.data_type = 'timestamp with time zone') INTO v_seen_ok;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema = r.sch
             AND c.table_name = r.tbl AND c.column_name = r.sync_col
             AND c.data_type = 'timestamp with time zone') INTO v_sync_ok;
    SELECT EXISTS (SELECT 1 FROM information_schema.columns c WHERE c.table_schema = r.sch
             AND c.table_name = r.tbl AND c.column_name = r.active_col
             AND c.data_type = 'boolean') INTO v_active_ok;

    v_parts := v_parts || format(
      $f$SELECT %1$L::text AS source_key, 'PRESENT'::text AS table_state,
                count(*)::bigint AS device_count,
                %5$s AS active_count,
                %6$s AS last_seen_at,
                CASE WHEN %6$s IS NULL THEN 'UNKNOWN' ELSE 'KNOWN' END::text AS last_seen_state,
                %7$s AS last_successful_sync_at,
                CASE WHEN %7$s IS NULL THEN 'UNKNOWN' ELSE 'KNOWN' END::text AS last_sync_state
           FROM %2$I.%3$I$f$,
      r.source_key, r.sch, r.tbl, NULL,
      CASE WHEN v_active_ok
           THEN format('(count(*) FILTER (WHERE %I IS TRUE))::bigint', r.active_col)
           ELSE 'NULL::bigint' END,
      CASE WHEN v_seen_ok THEN format('max(%I)', r.seen_col) ELSE 'NULL::timestamptz' END,
      CASE WHEN v_sync_ok THEN format('max(%I)', r.sync_col) ELSE 'NULL::timestamptz' END);
  END LOOP;

  v_sql := 'CREATE OR REPLACE VIEW torch_bearer.device_sync_summary_v1 '
        || 'WITH (security_invoker = false) AS '
        || array_to_string(v_parts, ' UNION ALL ');
  EXECUTE v_sql;
END
$build$;

-- ---------------------------------------------------------------------------
-- Privileges: deny by default, then grant exactly USAGE + 4x SELECT.
-- ---------------------------------------------------------------------------
REVOKE ALL ON SCHEMA torch_bearer FROM PUBLIC;
REVOKE ALL ON TABLE torch_bearer.wa_outbox_summary_v1       FROM PUBLIC;
REVOKE ALL ON TABLE torch_bearer.config_policy_summary_v1   FROM PUBLIC;
REVOKE ALL ON TABLE torch_bearer.migration_ledger_summary_v1 FROM PUBLIC;
REVOKE ALL ON TABLE torch_bearer.device_sync_summary_v1     FROM PUBLIC;

-- Supabase default privileges can auto-grant new relations to API roles; strip them.
DO $$
DECLARE
  v_role text;
BEGIN
  FOREACH v_role IN ARRAY ARRAY['anon', 'authenticated', 'service_role'] LOOP
    IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_role) THEN
      EXECUTE format('REVOKE ALL ON SCHEMA torch_bearer FROM %I', v_role);
      EXECUTE format('REVOKE ALL ON ALL TABLES IN SCHEMA torch_bearer FROM %I', v_role);
    END IF;
  END LOOP;
END
$$;

REVOKE ALL ON SCHEMA torch_bearer FROM torch_bearer_reader;
REVOKE ALL ON ALL TABLES IN SCHEMA torch_bearer FROM torch_bearer_reader;
GRANT USAGE ON SCHEMA torch_bearer TO torch_bearer_reader;
GRANT SELECT ON torch_bearer.wa_outbox_summary_v1        TO torch_bearer_reader;
GRANT SELECT ON torch_bearer.config_policy_summary_v1    TO torch_bearer_reader;
GRANT SELECT ON torch_bearer.migration_ledger_summary_v1 TO torch_bearer_reader;
GRANT SELECT ON torch_bearer.device_sync_summary_v1      TO torch_bearer_reader;

COMMENT ON SCHEMA torch_bearer IS
  'Private Torch Bearer read-only debugger surface. Never expose via PostgREST. Aggregate views only.';

-- ---------------------------------------------------------------------------
-- Self-check: fail the migration if the contract is not met.
-- ---------------------------------------------------------------------------
DO $$
DECLARE
  v_bad text;
BEGIN
  -- all four views present, security_invoker explicitly false
  SELECT string_agg(v.n, ', ') INTO v_bad
    FROM unnest(ARRAY['wa_outbox_summary_v1','config_policy_summary_v1',
                      'migration_ledger_summary_v1','device_sync_summary_v1']) v(n)
   WHERE NOT EXISTS (
     SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      WHERE n.nspname = 'torch_bearer' AND c.relname = v.n AND c.relkind = 'v'
        AND 'security_invoker=false' = ANY (coalesce(c.reloptions, ARRAY[]::text[])));
  IF v_bad IS NOT NULL THEN
    RAISE EXCEPTION 'torch_bearer view contract violated (missing or not security_invoker=false): %', v_bad;
  END IF;

  -- schema holds nothing but the four views
  IF (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
       WHERE n.nspname = 'torch_bearer' AND c.relkind NOT IN ('v')) <> 0
     OR (SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
          WHERE n.nspname = 'torch_bearer') <> 4 THEN
    RAISE EXCEPTION 'torch_bearer must contain exactly four views';
  END IF;

  -- reader is NOLOGIN and carries no direct privilege on any non-torch_bearer relation
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'torch_bearer_reader'
              AND (rolcanlogin OR rolsuper OR rolbypassrls OR rolcreaterole OR rolcreatedb)) THEN
    RAISE EXCEPTION 'torch_bearer_reader must be NOLOGIN/NOSUPERUSER/NOBYPASSRLS/NOCREATEROLE/NOCREATEDB';
  END IF;
  IF EXISTS (
    SELECT 1 FROM pg_class c
      JOIN pg_namespace n ON n.oid = c.relnamespace
      CROSS JOIN LATERAL aclexplode(c.relacl) a
      JOIN pg_roles r ON r.oid = a.grantee AND r.rolname = 'torch_bearer_reader'
     WHERE n.nspname <> 'torch_bearer'
  ) THEN
    RAISE EXCEPTION 'torch_bearer_reader must not hold grants outside torch_bearer';
  END IF;

  -- PUBLIC has nothing on the schema or its views
  IF EXISTS (
    SELECT 1 FROM pg_namespace n CROSS JOIN LATERAL aclexplode(n.nspacl) a
     WHERE n.nspname = 'torch_bearer' AND a.grantee = 0
  ) OR EXISTS (
    SELECT 1 FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
      CROSS JOIN LATERAL aclexplode(c.relacl) a
     WHERE n.nspname = 'torch_bearer' AND a.grantee = 0
  ) THEN
    RAISE EXCEPTION 'PUBLIC must hold no privilege on torch_bearer';
  END IF;
END
$$;
