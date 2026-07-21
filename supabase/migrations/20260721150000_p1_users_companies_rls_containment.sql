-- P1 security containment: close two unconditionally-permissive RLS policies.
--
-- Validated finding (re-confirmed against production metadata prior to this
-- migration; see P1_RLS_EMERGENCY_CONTAINMENT_PLAN.md for the full audit):
--
--   1. public.users."OASIS_ADMIN_FULL_CONTROL" is a PERMISSIVE ALL policy for
--      {authenticated} with USING (true) / WITH CHECK (true). Postgres ORs all
--      permissive policies for a command together, so this one policy alone
--      grants every authenticated session unrestricted SELECT/INSERT/UPDATE/
--      DELETE on every row of public.users, including role/company_id/
--      is_active/commission fields, regardless of the two other, correctly
--      scoped policies already on this table.
--
--   2. public.companies."OASIS_AUTH_INSERT_BYPASS" is a PERMISSIVE INSERT
--      policy for {authenticated} with WITH CHECK (true), letting any
--      authenticated session (including an unapproved buyer/PENDING account)
--      create arbitrary companies rows.
--
-- This migration is containment only: it removes those two policies plus one
-- additional pre-existing UPDATE policy on public.users ("Admins can update
-- users") discovered during implementation to independently reopen the same
-- self-escalation hole (see the DROP statement below for why), and replaces
-- all three with the minimum set of narrowly-scoped policies needed to
-- preserve every currently-working legitimate operation (self registration,
-- self-service non-authority profile edits, verified admin management,
-- staff company creation). It does not touch orders, payment, audit_log,
-- outlet, or department policies, does not normalize role casing, and does
-- not delete any row.
--
-- Replacement policies reuse get_user_role()/is_internal_staff() — the same
-- normalized, SECURITY DEFINER helpers already proven correct and live on
-- this exact table pair (see "Admins manage companies" and "Staff read all
-- companies" on public.companies) — rather than is_admin(), which is not
-- case-normalized and would silently exclude the production accounts whose
-- role is stored as uppercase 'SUPER_ADMIN'. Both helpers are SECURITY
-- DEFINER and internally bypass RLS, so referencing them here introduces no
-- recursive RLS evaluation.

BEGIN;

-- =============================================================================
-- A. public.users
-- =============================================================================

-- Security invariant being closed: no authenticated session may read/write
-- every row unconditionally. Drop the permissive ALL/true policy entirely.
DROP POLICY IF EXISTS "OASIS_ADMIN_FULL_CONTROL" ON public.users;

-- Security invariant: also drop the pre-existing "Admins can update users"
-- UPDATE policy (USING (is_admin() OR id = auth.uid()), no WITH CHECK).
-- This is NOT an unrelated policy left alone by accident: for an UPDATE
-- policy, an omitted WITH CHECK defaults to re-evaluating the USING
-- expression against the *new* row. That expression only ever inspects
-- `id` and `is_admin()` — never role/company_id/is_active/commission/etc —
-- so for any authenticated user's own row (id = auth.uid() is trivially
-- still true after the update) it imposes no column-level restriction at
-- all. Left in place, this policy alone (independent of
-- OASIS_ADMIN_FULL_CONTROL, and OR'd against the new restrictive policy
-- below because permissive policies are additive) would still let a
-- plain user set role = 'SUPER_ADMIN' on their own row. It is fully
-- superseded by "users_self_update_no_authority_change" (self, authority
-- columns pinned) and "users_admin_full_management" (admin-tier, via the
-- normalized get_user_role() rather than the case-sensitive is_admin()).
DROP POLICY IF EXISTS "Admins can update users" ON public.users;

-- Security invariant: self-registration may only create the caller's own
-- row, and only with the canonical PENDING role WelcomeGate.tsx already
-- sends today. A client cannot use this path to insert itself with any
-- elevated role — INSERT with role <> 'PENDING' is rejected by WITH CHECK.
DROP POLICY IF EXISTS "users_self_insert_pending_only" ON public.users;
CREATE POLICY "users_self_insert_pending_only"
  ON public.users
  FOR INSERT
  TO authenticated
  WITH CHECK (
    id = auth.uid()
    AND role = 'PENDING'
  );

-- Security invariant: self-update may only touch the caller's own row, and
-- every identity/authority-bearing column must be unchanged from its
-- currently stored value. This is what actually stops a user from PATCHing
-- their own role, company_id, active flag, sales-executive flag, commission
-- rate, invite status, or soft-delete marker — the WITH CHECK subqueries
-- compare the proposed new row's authority columns against what is
-- currently stored for that same row. Non-authority columns (e.g.
-- has_seen_tutorial) remain free to change via this policy.
DROP POLICY IF EXISTS "users_self_update_no_authority_change" ON public.users;
CREATE POLICY "users_self_update_no_authority_change"
  ON public.users
  FOR UPDATE
  TO authenticated
  USING (id = auth.uid())
  WITH CHECK (
    id = auth.uid()
    AND role IS NOT DISTINCT FROM (SELECT u.role FROM public.users u WHERE u.id = auth.uid())
    AND company_id IS NOT DISTINCT FROM (SELECT u.company_id FROM public.users u WHERE u.id = auth.uid())
    AND is_active IS NOT DISTINCT FROM (SELECT u.is_active FROM public.users u WHERE u.id = auth.uid())
    AND is_sales_executive IS NOT DISTINCT FROM (SELECT u.is_sales_executive FROM public.users u WHERE u.id = auth.uid())
    AND commission_rate_percentage IS NOT DISTINCT FROM (SELECT u.commission_rate_percentage FROM public.users u WHERE u.id = auth.uid())
    AND invite_status IS NOT DISTINCT FROM (SELECT u.invite_status FROM public.users u WHERE u.id = auth.uid())
    AND deleted_at IS NOT DISTINCT FROM (SELECT u.deleted_at FROM public.users u WHERE u.id = auth.uid())
  );

-- Security invariant: full row management (role assignment, activation,
-- commission changes, employee contact-info fixes, deletes) is available
-- only to a normalized admin-tier session. Reuses the exact expression
-- already live and proven on "Admins manage companies" on the sibling
-- table — not a new invention. Scoped with FOR ALL so it also covers
-- DELETE, which no other users policy grants to authenticated sessions.
DROP POLICY IF EXISTS "users_admin_full_management" ON public.users;
CREATE POLICY "users_admin_full_management"
  ON public.users
  FOR ALL
  TO authenticated
  USING (get_user_role(auth.uid()) = ANY (ARRAY['ADMIN', 'SUPER_ADMIN']))
  WITH CHECK (get_user_role(auth.uid()) = ANY (ARRAY['ADMIN', 'SUPER_ADMIN']));

-- =============================================================================
-- B. public.companies
-- =============================================================================

-- Security invariant being closed: no authenticated session may create a
-- companies row unconditionally. Every existing SELECT/UPDATE policy on
-- this table is unaffected — this bypass only ever covered INSERT.
DROP POLICY IF EXISTS "OASIS_AUTH_INSERT_BYPASS" ON public.companies;

-- Security invariant: only internal staff (the same population already
-- allowed to read every company via "Staff read all companies") may create
-- a companies row. Ordinary buyers and PENDING/unapproved accounts cannot
-- insert. Reuses that policy's exact expression verbatim so the create
-- and read authority for staff stay in lockstep.
DROP POLICY IF EXISTS "companies_staff_insert" ON public.companies;
CREATE POLICY "companies_staff_insert"
  ON public.companies
  FOR INSERT
  TO authenticated
  WITH CHECK (
    is_internal_staff(auth.uid())
    AND upper(get_user_role(auth.uid())) <> 'SALES_EXECUTIVE'
  );

COMMIT;
