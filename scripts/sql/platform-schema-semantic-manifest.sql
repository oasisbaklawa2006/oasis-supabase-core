BEGIN READ ONLY;
SET LOCAL statement_timeout = '90s';
SET LOCAL lock_timeout = '5s';
SET LOCAL search_path = pg_catalog, public;

WITH app_roles(role_name) AS (
  VALUES ('PUBLIC'::text), ('anon'::text), ('authenticated'::text), ('service_role'::text)
),
manifest(kind, key, value) AS (
  /* Namespace ownership for app-governed schemas. */
  SELECT
    'schema_owner',
    n.nspname,
    jsonb_build_object('owner', pg_get_userbyid(n.nspowner))
  FROM pg_namespace n
  WHERE n.nspname IN ('public', 'storage')

  UNION ALL

  /* Schema USAGE/CREATE privileges for application roles. */
  SELECT
    'schema_grant',
    format('%I:%s:%s', n.nspname,
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
      acl.privilege_type),
    jsonb_build_object('grantable', acl.is_grantable)
  FROM pg_namespace n
  JOIN LATERAL aclexplode(COALESCE(n.nspacl, acldefault('n', n.nspowner))) acl ON true
  LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
  JOIN app_roles ar
    ON ar.role_name = CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END
  WHERE n.nspname IN ('public', 'storage')

  UNION ALL

  /* Public object ownership is part of the authority boundary. */
  SELECT
    'relation_owner',
    format('%I.%I', n.nspname, c.relname),
    jsonb_build_object('owner', pg_get_userbyid(c.relowner), 'relkind', c.relkind)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p', 'v', 'm', 'S')

  UNION ALL

  SELECT
    'routine_owner',
    format('%I.%I(%s)', n.nspname, p.proname, pg_get_function_identity_arguments(p.oid)),
    jsonb_build_object('owner', pg_get_userbyid(p.proowner), 'kind', p.prokind)
  FROM pg_proc p
  JOIN pg_namespace n ON n.oid = p.pronamespace
  WHERE n.nspname = 'public'
    AND p.prokind IN ('f', 'p')

  UNION ALL

  SELECT
    'type_owner',
    format('%I.%I', n.nspname, t.typname),
    jsonb_build_object('owner', pg_get_userbyid(t.typowner), 'type_kind', t.typtype)
  FROM pg_type t
  JOIN pg_namespace n ON n.oid = t.typnamespace
  WHERE n.nspname = 'public'
    AND t.typtype IN ('e', 'd')

  UNION ALL

  /* Explicit column ACLs only. information_schema.column_privileges expands
     inherited/table-level privileges and is role-dependent, which would make
     the census vary with the connection role instead of the canonical ACL. */
  SELECT
    'column_grant',
    format('%I.%I:%I:%s:%s', n.nspname, c.relname, a.attname,
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
      acl.privilege_type),
    jsonb_build_object('grantable', acl.is_grantable)
  FROM pg_attribute a
  JOIN pg_class c ON c.oid = a.attrelid
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN LATERAL aclexplode(a.attacl) acl ON a.attacl IS NOT NULL
  LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
  JOIN app_roles ar
    ON ar.role_name = CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END
  WHERE n.nspname = 'public'
    AND c.relkind IN ('r', 'p', 'v', 'm')
    AND a.attnum > 0
    AND NOT a.attisdropped

  UNION ALL

  /* Public-schema default ACLs that can silently alter privileges of future objects. */
  SELECT
    'default_acl',
    format('%s:%I:%s:%s:%s', owner.rolname, n.nspname, d.defaclobjtype,
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
      acl.privilege_type),
    jsonb_build_object('grantable', acl.is_grantable)
  FROM pg_default_acl d
  JOIN pg_roles owner ON owner.oid = d.defaclrole
  JOIN pg_namespace n ON n.oid = d.defaclnamespace
  JOIN LATERAL aclexplode(d.defaclacl) acl ON true
  LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
  JOIN app_roles ar
    ON ar.role_name = CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END
  WHERE n.nspname = 'public'

  UNION ALL

  /* Storage bucket configuration is governed configuration, not mutable object
     data. Serialize only fields Oasis owns semantically; hosted Storage can add
     platform-internal columns independently of the pinned local CLI image. */
  SELECT
    'storage_bucket',
    b.id::text,
    jsonb_build_object(
      'name', b.name,
      'public', b.public,
      'file_size_limit', b.file_size_limit,
      'allowed_mime_types', b.allowed_mime_types
    )
  FROM storage.buckets b

  UNION ALL

  /* App-defined RLS policies on the two storage authority tables. */
  SELECT
    'storage_policy',
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
  WHERE p.schemaname = 'storage'
    AND p.tablename IN ('buckets', 'objects')

  UNION ALL

  /* Application-role grants on storage authority relations. */
  SELECT
    'storage_relation_grant',
    format('%I.%I:%s:%s', n.nspname, c.relname,
      CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END,
      acl.privilege_type),
    jsonb_build_object('grantable', acl.is_grantable)
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  JOIN LATERAL aclexplode(COALESCE(c.relacl, acldefault('r', c.relowner))) acl ON true
  LEFT JOIN pg_roles grantee ON grantee.oid = acl.grantee
  JOIN app_roles ar
    ON ar.role_name = CASE WHEN acl.grantee = 0 THEN 'PUBLIC' ELSE grantee.rolname END
  WHERE n.nspname = 'storage'
    AND c.relname IN ('buckets', 'objects')
    AND c.relkind IN ('r', 'p')
)
SELECT jsonb_build_object('kind', kind, 'key', key, 'value', value)::text
FROM manifest
ORDER BY kind COLLATE "C", key COLLATE "C";

COMMIT;
