-- Final certification repair: B2B application review authority.
-- Admin review is a privileged onboarding action. Ordinary internal staff may
-- not approve/reject/delete an application through direct table access or
-- through a SECURITY DEFINER approval helper that only checks "internal staff".

begin;

create or replace function public.enforce_b2b_application_review_authority_v1()
returns trigger
language plpgsql
security definer
set search_path = 'pg_catalog','public','auth'
as $$
declare
  v_role text := upper(coalesce(public.get_user_role(auth.uid()), ''));
  v_service boolean := auth.role() = 'service_role';
  v_review_mutation boolean := false;
begin
  if tg_op = 'DELETE' then
    if not v_service and v_role not in ('ADMIN','SUPER_ADMIN') then
      raise exception 'B2B_APPLICATION_ADMIN_REVIEW_REQUIRED'
        using errcode='42501';
    end if;
    return old;
  end if;

  if tg_op = 'UPDATE' then
    v_review_mutation :=
      new.status is distinct from old.status
      or new.reviewed_by is distinct from old.reviewed_by
      or new.reviewed_at is distinct from old.reviewed_at
      or new.assigned_price_tier is distinct from old.assigned_price_tier
      or new.rejection_reason is distinct from old.rejection_reason
      or new.admin_notes is distinct from old.admin_notes
      or new.requested_info_at is distinct from old.requested_info_at
      or new.requested_info_note is distinct from old.requested_info_note
      or new.resolved_company_id is distinct from old.resolved_company_id;

    if v_review_mutation and not v_service and v_role not in ('ADMIN','SUPER_ADMIN') then
      raise exception 'B2B_APPLICATION_ADMIN_REVIEW_REQUIRED'
        using errcode='42501';
    end if;
    return new;
  end if;

  return coalesce(new,old);
end;
$$;

drop trigger if exists trg_b2b_application_review_authority_v1 on public.b2b_applications;
create trigger trg_b2b_application_review_authority_v1
before update or delete on public.b2b_applications
for each row execute function public.enforce_b2b_application_review_authority_v1();

drop policy if exists "Staff delete applications" on public.b2b_applications;
create policy "Admins delete applications"
on public.b2b_applications
for delete
to authenticated
using (
  public.is_internal_staff(auth.uid())
  and upper(coalesce(public.get_user_role(auth.uid()),'')) in ('ADMIN','SUPER_ADMIN')
);

revoke all on function public.enforce_b2b_application_review_authority_v1() from public, anon, authenticated;
grant execute on function public.enforce_b2b_application_review_authority_v1() to service_role;

comment on function public.enforce_b2b_application_review_authority_v1() is
  'Fail-closed B2B onboarding review boundary. Only ADMIN/SUPER_ADMIN or service_role may mutate review/approval fields or delete an application.';

commit;
