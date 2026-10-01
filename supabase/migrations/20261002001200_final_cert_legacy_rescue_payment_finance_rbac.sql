-- Final certification repair: close legacy rescue-payment finance bypass.
-- Evidence upload remains compatible, but verification/deletion is Finance/Admin only.

begin;

create or replace function public.guard_order_payment_authority_mutation()
returns trigger
language plpgsql
set search_path to 'pg_catalog','public','auth'
as $$
declare
  v_role text := upper(coalesce(public.get_user_role(auth.uid()), ''));
  v_finance_authority boolean := v_role in (
    'FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER'
  );
begin
  if auth.uid() is null
     and pg_catalog.pg_has_role(
       current_user,
       (select pg_catalog.pg_get_userbyid(c.relowner)
          from pg_catalog.pg_class c
         where c.oid='public.order_payments'::regclass),
       'USAGE') then
    return case when tg_op='DELETE' then old else new end;
  end if;

  -- Compatibility: authenticated staff may capture a rescue proof as uploaded.
  -- Upload is evidence intake, not finance verification.
  if tg_op='INSERT'
     and NEW.idempotency_key IS NULL
     and NEW.payment_type = 'rescue'
     and NEW.status = 'uploaded'
     and public.is_internal_staff(auth.uid()) then
    return new;
  end if;

  -- Verification changes financial truth and may unlock credit. Finance/Admin only.
  if tg_op='UPDATE'
     and OLD.idempotency_key IS NULL and NEW.idempotency_key IS NULL
     and OLD.payment_type = 'rescue' and NEW.payment_type = 'rescue'
     and OLD.status = 'uploaded' and NEW.status IN ('uploaded','verified')
     and v_finance_authority then
    return new;
  end if;

  if tg_op='DELETE'
     and OLD.idempotency_key IS NULL
     and OLD.payment_type = 'rescue'
     and v_finance_authority then
    return old;
  end if;

  if not exists (
    select 1 from public.order_payment_authority_scopes s
     where s.backend_pid=pg_backend_pid()
       and s.transaction_id=txid_current()
       and (s.payment_id is null or s.payment_id=case when tg_op='DELETE' then old.id else new.id end)
  ) then
    raise exception 'ORDER_PAYMENT_AUTHORITY_REQUIRED' using errcode='42501';
  end if;

  return case when tg_op='DELETE' then old else new end;
end;
$$;

drop policy if exists "Staff update legacy credit rescue payments" on public.order_payments;
create policy "Finance update legacy credit rescue payments"
on public.order_payments
for update to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in
      ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER')
  and payment_type='rescue'
  and idempotency_key is null
)
with check (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in
      ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER')
  and payment_type='rescue'
  and idempotency_key is null
  and status in ('uploaded','verified')
);

drop policy if exists "Staff delete legacy credit rescue payments" on public.order_payments;
create policy "Finance delete legacy credit rescue payments"
on public.order_payments
for delete to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in
      ('FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER')
  and payment_type='rescue'
  and idempotency_key is null
);

comment on function public.guard_order_payment_authority_mutation() is
  'Canonical order-payment mutation guard. Legacy rescue upload remains compatible; verification/deletion requires Finance/Admin authority or a governed mutation scope.';

commit;
