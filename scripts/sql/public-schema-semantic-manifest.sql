BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = pg_catalog, public;

WITH manifest(kind, key, value) AS (
  /* Tables / partitioned tables: structural flags only, never data state. */
  SELECT
    'table',
    format('%I.%I', n.nspname, c.relname),
    jsonb_build_object(
      'relkind', c.relkind,
      'persistence', c.relpersistence,
      'rls_enabled', c.relrowsecurity,
      'rls_forced', c.relforcerowsecurity,
      'replica_identity', c.relreplident,
      'reloptions', COALESCE(to_jsonb(c.reloptions), '[]'::jsonb)
    )
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p')

  UNION ALL

  /* Columns including generated/identity/default/collation semantics. */
  SELECT
    'column',
    format('%I.%I.%s:%I', n.nspname, c.relname, a.attnum, a.attname),
    jsonb_build_object(
      'type', format_type(a.atttypid, a.atttypmod),
      'not_null', a.attnotnull,
      'identity', a.attidentity,
      'generated', a.attgenerated,
      'default', pg_get_expr(ad.adbin, ad.adrelid, true),
      'collation', CASE
        WHEN a.attcollation = 0 THEN NULL
        ELSE format('%I.%I', cn.nspname, coll.collname)
      END
    )
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  LEFT JOIN pg_attrdef ad ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
  LEFT JOIN pg_collation coll ON coll.oid = a.attcollation
  LEFT JOIN pg_namespace cn ON cn.oid = coll.collnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    AND a.attnum > 0
    AND NOT a.attisdropped

  UNION ALL

  /* Table constraints. */
  SELECT
    'constraint',
    format('%I.%I:%I', n.nspname, c.relname, con.conname),
    jsonb_build_object(
      'type', con.contype,
      'deferrable', con.condeferrable,
      'deferred', con.condeferred,
      'validated', con.convalidated,
      'definition', pg_get_constraintdef(con.oid, true)
    )
  FROM pg_constraint con
  JOIN pg_class c ON c.oid = con.conrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'

  UNION ALL

  /* Index definitions and validity. */
  SELECT
    'index',
    format('%I.%I:%I', tn.nspname, tbl.relname, idx.relname),
    jsonb_build_object(
      'unique', i.indisunique,
      'primary', i.indisprimary,
      'valid', i.indisvalid,
      'ready', i.indisready,
      'definition', pg_get_indexdef(i.indexrelid)
    )
  FROM pg_index i
  JOIN pg_class tbl ON tbl.oid = i.indrelid
  JOIN pg_namespace tn ON tn.oid = tbl.relnamespace
  JOIN pg_class idx ON idx.oid = i.indexrelid
  WHERE tn.nspname = 'public'

  UNION ALL

  /* Views and materialized views, including security reloptions. */
  SELECT
    CASE c.relkind WHEN 'm' THEN 'materialized_view' ELSE 'view' END,
    format('%I.%I', n.nspname, c.relname),
    jsonb_build_object(
      'definition', pg_get_viewdef(c.oid, true),
      'reloptions', COALESCE(
        (SELECT jsonb_agg(opt ORDER BY opt) FROM unnest(c.reloptions) AS opt),
        '[]'::jsonb
      )
    )
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('v', 'm')

  UNION ALL

  /* Functions / procedures keyed by identity arguments, not unstable OIDs. */
  SELECT
    CASE p.prokind WHEN 'p' THEN 'procedure' ELSE 'function' END,
    format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)),
    jsonb_build_object(
      'return_type', pg_get_function_result(p.oid),
      'volatility', p.provolatile,
      'strict', p.proisstrict,
      'security_definer', p.prosecdef,
      'leakproof', p.proleakproof,
      'parallel', p.proparallel,
      'config', COALESCE(
        (SELECT jsonb_agg(cfg ORDER BY cfg) FROM unnest(p.proconfig) AS cfg),
        '[]'::jsonb
      ),
      'definition', pg_get_functiondef(p.oid)
    )
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind IN ('f', 'p')

  UNION ALL

  /* Non-internal triggers. */
  SELECT
    'trigger',
    format('%I.%I:%I', n.nspname, c.relname, t.tgname),
    jsonb_build_object(
      'enabled', t.tgenabled,
      'definition', pg_get_triggerdef(t.oid, true)
    )
  FROM pg_trigger t
  JOIN pg_class c ON c.oid = t.tgrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND NOT t.tgisinternal

  UNION ALL

  /* RLS policies with role names sorted for OID-independent comparison. */
  SELECT
    'policy',
    format('%I.%I:%I', p.schemaname, p.tablename, p.policyname),
    jsonb_build_object(
      'permissive', p.permissive,
      'roles', COALESCE(
        (SELECT jsonb_agg(role_name ORDER BY role_name) FROM unnest(p.roles) AS role_name),
        '[]'::jsonb
      ),
      'command', p.cmd,
      'using', p.qual,
      'with_check', p.with_check
    )
  FROM pg_policies p
  WHERE p.schemaname = 'public'

  UNION ALL

  /* Enum labels preserve enum ordering. */
  SELECT
    'enum',
    format('%I.%I', n.nspname, t.typname),
    jsonb_build_object(
      'labels', (
        SELECT jsonb_agg(e.enumlabel ORDER BY e.enumsortorder)
        FROM pg_enum e
        WHERE e.enumtypid = t.oid
      )
    )
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public'
    AND t.typtype = 'e'

  UNION ALL

  /* Domains, including domain constraints. */
  SELECT
    'domain',
    format('%I.%I', n.nspname, t.typname),
    jsonb_build_object(
      'base_type', format_type(t.typbasetype, t.typtypmod),
      'not_null', t.typnotnull,
      'default', t.typdefault,
      'collation', CASE
        WHEN t.typcollation = 0 THEN NULL
        ELSE format('%I.%I', cn.nspname, coll.collname)
      END,
      'constraints', COALESCE((
        SELECT jsonb_agg(
          jsonb_build_object('name', con.conname, 'definition', pg_get_constraintdef(con.oid, true))
          ORDER BY con.conname
        )
        FROM pg_constraint con
        WHERE con.contypid = t.oid
      ), '[]'::jsonb)
    )
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  LEFT JOIN pg_collation coll ON coll.oid = t.typcollation
  LEFT JOIN pg_namespace cn ON cn.oid = coll.collnamespace
  WHERE n.nspname = 'public'
    AND t.typtype = 'd'

  UNION ALL

  /* Sequence configuration only; never current sequence values. */
  SELECT
    'sequence',
    format('%I.%I', n.nspname, c.relname),
    jsonb_build_object(
      'data_type', format_type(s.seqtypid, NULL),
      'start', s.seqstart,
      'increment', s.seqincrement,
      'min', s.seqmin,
      'max', s.seqmax,
      'cache', s.seqcache,
      'cycle', s.seqcycle
    )
  FROM pg_sequence s
  JOIN pg_class c ON c.oid = s.seqrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'

  UNION ALL

  /* App-relevant table/view/sequence privileges, normalized to role names. */
  SELECT
    'relation_grant',
    format(
      '%I.%I:%s:%s',
      n.nspname,
      c.relname,
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
      acl.privilege_type
    ),
    jsonb_build_object('grantable', acl.is_grantable)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN LATERAL aclexplode(
    COALESCE(
      c.relacl,
      acldefault(CASE WHEN c.relkind = 'S' THEN 'S'::"char" ELSE 'r'::"char" END, c.relowner)
    )
  ) acl ON true
  LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p', 'v', 'm', 'S')
    AND (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END)
      IN ('PUBLIC', 'anon', 'authenticated', 'service_role')

  UNION ALL

  /* App-relevant routine EXECUTE privileges, including PostgreSQL defaults. */
  SELECT
    'routine_grant',
    format(
      '%I.%I(%s):%s:%s',
      n.nspname,
      p.proname,
      pg_get_function_identity_arguments(p.oid),
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
      acl.privilege_type
    ),
    jsonb_build_object('grantable', acl.is_grantable)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  JOIN LATERAL aclexplode(COALESCE(p.proacl, acldefault('f', p.proowner))) acl ON true
  LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
  WHERE n.nspname = 'public'
    AND p.prokind IN ('f', 'p')
    AND (CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END)
      IN ('PUBLIC', 'anon', 'authenticated', 'service_role')

  UNION ALL

  /* Realtime publication options. */
  SELECT
    'publication',
    p.pubname,
    jsonb_build_object(
      'all_tables', p.puballtables,
      'insert', p.pubinsert,
      'update', p.pubupdate,
      'delete', p.pubdelete,
      'truncate', p.pubtruncate,
      'via_partition_root', p.pubviaroot
    )
  FROM pg_publication p
  WHERE p.pubname = 'supabase_realtime'

  UNION ALL

  /* Explicit public-schema table membership in the Realtime publication. */
  SELECT
    'publication_table',
    format('%s:%I.%I', p.pubname, n.nspname, c.relname),
    '{}'::jsonb
  FROM pg_publication_rel pr
  JOIN pg_publication p ON p.oid = pr.prpubid
  JOIN pg_class c ON c.oid = pr.prrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE p.pubname = 'supabase_realtime'
    AND n.nspname = 'public'

  UNION ALL

  /* Schema-level publication membership (PG15+) when configured. */
  SELECT
    'publication_schema',
    format('%s:%I', p.pubname, n.nspname),
    '{}'::jsonb
  FROM pg_publication_namespace pn
  JOIN pg_publication p ON p.oid = pn.pnpubid
  JOIN pg_namespace n ON n.oid = pn.pnnspid
  WHERE p.pubname = 'supabase_realtime'
    AND n.nspname = 'public'
)
SELECT jsonb_build_object('kind', kind, 'key', key, 'value', value)::text
FROM manifest
ORDER BY kind COLLATE "C", key COLLATE "C";

COMMIT;