-- SECURITY FIX: close two privilege-escalation paths where a permissive RLS
-- INSERT policy fed a SECURITY DEFINER trigger that granted privileged state
-- with no independent server-side authority/verification check.
--
-- ISSUE 1 — b2b_applications self-approval:
--   ANON_CAN_SUBMIT_APPLICATION (anon, WITH CHECK true) and "Anyone can apply"
--   (public, WITH CHECK true) allowed ANY caller, including unauthenticated
--   anon, to INSERT a b2b_applications row with status='approved' and an
--   arbitrary user_id. trg_activate_company_on_approval and
--   trg_link_buyer_on_approval fire on INSERT (not just UPDATE) and, with no
--   caller-authority check, would activate the matching company and grant
--   the named user_id a 'b2b_buyer' role + company linkage — a full
--   authentication/authorization bypass reachable by a single anonymous
--   PostgREST INSERT. UPDATE was already staff-only ("Staff manage
--   applications"); this migration does not change UPDATE.
--
-- ISSUE 2 — order_payments credit-unlock via fabricated 'rescue' payments:
--   "Buyers insert own company payments" / "buyer_insert_own_order_payments"
--   restrict INSERT only by company ownership of the order, with no
--   restriction on payment_type, amount, status, or verified_by/verified_at.
--   handle_credit_payment() (AFTER INSERT, SECURITY DEFINER) sums
--   payment_type='rescue' rows with no status filter and unfreezes the
--   company's credit once the cumulative sum reaches 70% of
--   total_outstanding. A buyer could insert a payment_type='rescue' row
--   with a fabricated amount (and could even self-set status='verified')
--   and unlock credit with no real payment or finance verification.
--
-- Fix strategy (two independent layers per object, so a regression in one
-- layer does not reopen the hole):
--   (a) RLS: buyer-facing INSERT policies now force every privileged/
--       reviewer-owned field to its safe default at insert time.
--   (b) Trigger functions: add an explicit server-side authority/
--       verification guard inside the SECURITY DEFINER function body
--       itself, so the privileged side effect cannot fire even if a future
--       migration loosens the RLS policy above it.

-- ── b2b_applications: RLS ────────────────────────────────────────────────

drop policy if exists "ANON_CAN_SUBMIT_APPLICATION" on public.b2b_applications;
drop policy if exists "Anyone can apply" on public.b2b_applications;
drop policy if exists "Applicants insert own application" on public.b2b_applications;

create policy "Applicants submit safe pending application"
  on public.b2b_applications
  for insert
  to anon, authenticated
  with check (
    status = 'pending'
    and reviewed_by is null
    and reviewed_at is null
    and assigned_price_tier is null
    and rejection_reason is null
    and admin_notes is null
    and requested_info_at is null
    and requested_info_note is null
    and (
      (auth.uid() is not null and user_id = auth.uid())
      or (auth.uid() is null and user_id is null)
    )
  );

-- ── b2b_applications: trigger-level defense in depth ────────────────────

create or replace function public.activate_company_on_application_approval()
  returns trigger
  language plpgsql security definer
  set search_path to 'public'
  as $$
begin
  if not (new.status = 'approved' and (tg_op = 'INSERT' or old.status is distinct from 'approved')) then
    return new;
  end if;

  if not (auth.role() = 'service_role' or public.is_internal_staff(auth.uid())) then
    return new;
  end if;

  update public.companies
  set status = 'active'
  where business_name = new.business_name
    and coalesce(status,'pending') <> 'active';

  return new;
end;
$$;

create or replace function public.link_buyer_on_application_approval()
  returns trigger
  language plpgsql security definer
  set search_path to 'public'
  as $$
declare
  resolved_company_id uuid;
begin
  if new.status <> 'approved' or new.user_id is null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.status = 'approved' then
    return new;
  end if;

  if not (auth.role() = 'service_role' or public.is_internal_staff(auth.uid())) then
    return new;
  end if;

  select id into resolved_company_id
  from public.companies
  where business_name = new.business_name
  limit 1;

  if resolved_company_id is null then
    insert into public.companies (business_name, gst_number, phone, registered_address, status)
    values (new.business_name, new.gst_number, new.contact_phone, new.registered_address, 'active')
    returning id into resolved_company_id;
  end if;

  insert into public.users (id, email, role, company_id)
  values (new.user_id, new.contact_email, 'b2b_buyer', resolved_company_id)
  on conflict (id) do update
    set company_id = coalesce(public.users.company_id, excluded.company_id),
        role = coalesce(nullif(public.users.role, ''), excluded.role);

  return new;
end;
$$;

-- ── order_payments: RLS ──────────────────────────────────────────────────

drop policy if exists "Buyers insert own company payments" on public.order_payments;
-- "buyer_insert_own_order_payments" is a redundant duplicate of the policy
-- below, but weaker: it omits the company_id/created_by ownership checks
-- entirely, so a caller satisfying it could attribute a payment's
-- order_payments.company_id to a company other than the one that actually
-- owns the order. Since RLS INSERT policies are OR'ed, its mere presence
-- would silently reopen this migration's fix. Removed outright rather than
-- patched — "Buyers insert own company payments" already fully covers the
-- legitimate case with correct predicates.
drop policy if exists "buyer_insert_own_order_payments" on public.order_payments;

create policy "Buyers insert own company payments"
  on public.order_payments
  for insert
  to authenticated
  with check (
    not (created_by is distinct from auth.uid())
    and not (company_id is distinct from public.auth_buyer_company_id())
    and status = 'uploaded'
    and verified_by is null
    and verified_at is null
    and rejection_reason is null
    and exists (
      select 1 from public.orders o
      where o.id = order_payments.order_id
        and o.company_id = public.auth_buyer_company_id()
    )
  );

-- ── order_payments: trigger-level defense in depth ──────────────────────
-- Only finance-verified rescue payments (status='verified', set exclusively
-- via the staff-only UPDATE policy) may ever count toward the credit-rescue
-- threshold, independent of whatever status a caller could set at insert.

create or replace function public.handle_credit_payment()
  returns trigger
  language plpgsql security definer
  set search_path to 'public'
  as $$
declare
  comp record;
  cumulative_rescue numeric;
  month_end timestamptz;
begin
  if new.payment_type is distinct from 'rescue' then
    return new;
  end if;

  if new.status is distinct from 'verified' then
    return new;
  end if;

  select id, is_frozen, total_outstanding into comp
  from public.companies where id = new.company_id for update;

  if not found or not comp.is_frozen then
    return new;
  end if;

  select coalesce(sum(amount), 0) into cumulative_rescue
  from public.order_payments
  where company_id = new.company_id
    and payment_type = 'rescue'
    and status = 'verified'
    and created_at >= coalesce((select rescue_payment_date from public.companies where id = new.company_id), '1970-01-01'::timestamptz);

  if cumulative_rescue >= (comp.total_outstanding * 0.70) then
    month_end := (date_trunc('month', now()) + interval '1 month' - interval '1 second');

    perform set_config('app.system_credit_op', 'on', true);
    update public.companies
    set is_frozen = false,
        rescue_payment_date = coalesce(rescue_payment_date, now()),
        settlement_deadline = month_end
    where id = new.company_id;
    perform set_config('app.system_credit_op', 'off', true);

    insert into public.audit_logs (
      action_type, module_name, entity_name, entity_id, actor_id, reason, new_value, risk_level
    ) values (
      'CREDIT_UNFREEZE_AUTO', 'credit_governance', 'companies', new.company_id::text, auth.uid(),
      'Automated unlock: 70% verified rescue threshold reached',
      jsonb_build_object(
        'transaction_id', new.id,
        'reference_no', new.reference_no,
        'rescue_amount', new.amount,
        'cumulative_rescue', cumulative_rescue,
        'outstanding_at_unlock', comp.total_outstanding,
        'settlement_deadline', month_end
      ),
      'high'
    );

    -- credit_rescue_events_event_type_check has never permitted 'auto_unlock'
    -- (only 'frozen'/'rescue_payment'/'unlocked'/'month_end_lock'/
    -- 'manual_override'/'settlement_deadline_set' — see
    -- 20260723161256_legacy_role_authority_baseline.sql:5397); the original
    -- function used 'auto_unlock' regardless, so this insert has always
    -- raised a constraint violation in production whenever the 70% rescue
    -- threshold was actually reached, rolling back the whole verification.
    -- Corrected to the existing permitted value with the matching meaning.
    insert into public.credit_rescue_events (
      company_id, event_type, amount, outstanding_at_event, notes, actor_id
    ) values (
      new.company_id, 'unlocked', new.amount, comp.total_outstanding,
      'Auto-unlock via payment ' || new.id::text, auth.uid()
    );
  end if;

  return new;
end;
$$;

-- handle_credit_payment previously fired AFTER INSERT only, so a payment
-- verified later via UPDATE never re-evaluated the unlock condition. Add an
-- AFTER UPDATE OF status trigger so a legitimate finance verification can
-- still unlock credit once the verified threshold is actually reached.
drop trigger if exists trg_credit_payment_verified on public.order_payments;
create trigger trg_credit_payment_verified
  after update of status on public.order_payments
  for each row
  when (new.status = 'verified' and old.status is distinct from 'verified')
  execute function public.handle_credit_payment();

-- The payment_type column comment has always documented 'rescue' as a valid
-- value (and handle_credit_payment has always branched on it), but the CHECK
-- constraint never actually allowed it — payment_type='rescue' has been
-- unreachable since this table was created, in every environment. Fixed
-- alongside this security migration since it's the same object and the fix
-- above is otherwise unreachable/untestable without it.
alter table public.order_payments
  drop constraint if exists order_payments_payment_type_check;
alter table public.order_payments
  add constraint order_payments_payment_type_check
  check (payment_type = any (array['advance'::text, 'balance'::text, 'adjustment'::text, 'rescue'::text]));

-- ── least privilege: these are trigger-only functions, never a direct
-- client-callable RPC. The trigger mechanism invokes them regardless of the
-- triggering role's own grants (SECURITY DEFINER runs as owner), so direct
-- anon/authenticated EXECUTE was always unnecessary — revoke it.

revoke all on function public.activate_company_on_application_approval() from public, anon, authenticated;
grant all on function public.activate_company_on_application_approval() to service_role;

revoke all on function public.link_buyer_on_application_approval() from public, anon, authenticated;
grant all on function public.link_buyer_on_application_approval() to service_role;

revoke all on function public.handle_credit_payment() from public, anon, authenticated;
grant all on function public.handle_credit_payment() to service_role;
