-- Reserve the phone alias namespace for the verified MSG91 exchange.
-- GoTrue writes admin app_metadata after the initial email write, in the
-- same transaction. Check the final row at commit instead of the first write.
create function public.msg91_guard_reserved_phone_alias_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  final_email text;
  alias_proof jsonb;
begin
  if tg_op = 'UPDATE' then
    if lower(btrim(new.email)) is not distinct from lower(btrim(old.email)) then
      return null;
    end if;
  end if;

  select u.email, u.raw_app_meta_data -> 'msg91_verified_phone_alias'
    into final_email, alias_proof
    from auth.users as u
    where u.id = new.id;

  -- A subsequent write in the transaction can supersede this trigger event.
  if final_email is distinct from new.email then
    return null;
  end if;

  if final_email !~ '^91[6-9][0-9]{9}@phone[.]oasis[.]local$'
    or alias_proof ->> 'email' is distinct from final_email
    or nullif(alias_proof ->> 'nonce', '') is null then
    raise exception 'Reserved phone alias requires verified provisioning'
      using errcode = '23514';
  end if;

  if tg_op = 'UPDATE' then
    if alias_proof is not distinct from old.raw_app_meta_data -> 'msg91_verified_phone_alias' then
      raise exception 'Reserved phone alias requires fresh verified provisioning'
        using errcode = '23514';
    end if;
  end if;

  -- Consume the authorization. It must never authorize a later email change.
  update auth.users
    set raw_app_meta_data = raw_app_meta_data - 'msg91_verified_phone_alias'
    where id = new.id;

  return null;
end;
$$;

revoke all on function public.msg91_guard_reserved_phone_alias_v1()
  from public, anon, authenticated, service_role;

create constraint trigger msg91_reserved_phone_alias_guard_v1
after insert or update on auth.users
deferrable initially deferred
for each row
when (lower(btrim(new.email)) like '%@phone.oasis.local')
execute function public.msg91_guard_reserved_phone_alias_v1();
