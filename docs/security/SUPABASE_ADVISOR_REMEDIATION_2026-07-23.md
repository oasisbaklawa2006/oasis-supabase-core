# Supabase Advisor Remediation — 2026-07-23

## Production project

`tcxvcatsqqertcnycuop`

## Completed in this tranche

1. Replaced two ERROR-level RLS policies that trusted editable `auth.user_metadata`:
   - `public.orders.operations_view_in_production_orders`
   - `public.whatsapp_messages.whatsapp_messages_finance_ops`
2. Both policies now use database-backed role authority through `public.get_user_role(auth.uid())` and apply only to `authenticated`.
3. Added `access_permissions.requires_step_up`.
4. Marked `rbac.manage` as requiring step-up authentication.
5. Added `public.has_step_up_auth()` using the Supabase JWT `aal` claim.
6. Hardened `has_active_company_membership` and `has_app_permission` against caller impersonation.
7. Removed anonymous execution from the new privileged helper functions.
8. Set fixed search paths on three advisor-flagged functions.

## Runtime evidence

Using `admin@oasisbaklawa.com`:

| Session | step-up | org.read | rbac.manage |
|---|---:|---:|---:|
| AAL1 | false | true | false |
| AAL2 | true | true | true |

The migration applied successfully to production. A subsequent security-advisor run no longer reported either `rls_uses_user_metadata` error and no longer reported anonymous execution for `has_active_company_membership` or `has_app_permission`.

## Remaining advisor findings

The advisor is not clean. Remaining historical findings include:

- security-definer views
- legacy mutable function search paths
- permissive write policies
- broad execution grants on historical security-definer functions
- public storage-bucket listing
- RLS-enabled tables with no policy
- leaked-password protection disabled
- `pg_net` installed in the public schema

These require usage and dependency review. They must not be bulk-modified because several are tied to live Customer App, AI Studio, Central, WhatsApp and OLS workflows.

## Point 19 truth classification

- DOCUMENTED: yes
- CODED: yes
- MIGRATED: yes
- TESTED: yes
- DEPLOYED: yes
- RUNTIME VERIFIED: yes
