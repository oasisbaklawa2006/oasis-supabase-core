# App-Verse Points 16–18 Runtime Evidence — 2026-07-23

## Scope

Runtime implementation evidence for shared authentication identity profiles, company/branch/contact hierarchy and scoped capability RBAC.

## Production project

Supabase project: `tcxvcatsqqertcnycuop`

## Migration

Applied successfully through the Supabase migration API under migration name:

`app_verse_identity_hierarchy_rbac`

## Objects verified

The following production tables exist:

- `identity_profiles`
- `org_companies`
- `org_branches`
- `org_contacts`
- `org_memberships`
- `org_membership_branch_scopes`
- `access_permissions`
- `role_permission_grants`
- `org_membership_roles`

The following helper functions exist:

- `has_active_company_membership(uuid, uuid)`
- `has_app_permission(uuid, text, uuid, uuid)`

## RLS verification

All nine new tables have RLS enabled.

Each table has two policies: read/select and privileged management.

## Contract verification

The repository contract assertions were executed against production inside a transaction ending in `rollback`.

Result: PASS.

Assertions covered:

- all required tables exist
- both helper functions exist
- RLS is enabled on every new table
- four canonical permissions are active
- `super_admin` has `rbac.manage`

## Legacy compatibility verification

Existing `is_team_member` behaviour remained unchanged:

| User | is_team_member | org.read | rbac.manage |
|---|---:|---:|---:|
| `admin@oasisbaklawa.com` | true | true | true |
| `purecocoa@live.in` | true | true | true |
| `dinesh_mutreja@yahoo.co.in` | false | false | false |

No existing role mapping was changed.

## Truth classification

- DOCUMENTED: yes
- CODED: yes
- MIGRATED: yes
- TESTED: yes — production contract assertions and compatibility checks
- DEPLOYED: yes — production Supabase
- RUNTIME VERIFIED: yes — object, RLS, permission and compatibility queries

## Remaining application work

Application screens and workflows still need to consume these shared contracts in later programme points. This evidence closes the Core foundation only; it does not claim every application already uses it.
