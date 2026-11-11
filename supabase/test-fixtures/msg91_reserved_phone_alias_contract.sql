-- Run against the scratch auth.users table after installing the guard.
begin;
set local role supabase_auth_admin;

insert into auth.users (email) values ('ordinary@example.test');
update auth.users set email = 'updated@example.test' where email = 'ordinary@example.test';

do $$
begin
  begin
    insert into auth.users (email, raw_user_meta_data)
      values ('916000000101@PHONE.OASIS.LOCAL', '{"msg91_verified_phone_alias":{"email":"916000000101@phone.oasis.local","nonce":"untrusted"}}');
    set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;
    raise exception 'Unverified signup was accepted';
  exception when check_violation then
    if sqlerrm <> 'Reserved phone alias requires verified provisioning' then raise; end if;
  end;

  begin
    update auth.users set email = '916000000102@phone.oasis.local'
      where email = 'updated@example.test';
    set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;
    raise exception 'Unverified email change was accepted';
  exception when check_violation then
    if sqlerrm <> 'Reserved phone alias requires verified provisioning' then raise; end if;
  end;
end;
$$;

-- Mirror GoTrue admin ordering: email first, then merged app metadata.
insert into auth.users (email, raw_app_meta_data)
  values ('916000000103@phone.oasis.local', '{"provider":"phone","retained":true}');
update auth.users
  set raw_app_meta_data = raw_app_meta_data ||
    '{"msg91_verified_phone_alias":{"email":"916000000103@phone.oasis.local","nonce":"admin-create"}}'::jsonb
  where email = '916000000103@phone.oasis.local';

update auth.users set email = '916000000102@phone.oasis.local',
  raw_app_meta_data = '{"provider":"email","retained":true}'
  where email = 'updated@example.test';
update auth.users
  set raw_app_meta_data = raw_app_meta_data ||
    '{"msg91_verified_phone_alias":{"email":"916000000102@phone.oasis.local","nonce":"admin-bind"}}'::jsonb
  where email = '916000000102@phone.oasis.local';

set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;
set constraints auth.msg91_reserved_phone_alias_guard_v1 deferred;

do $$
begin
  if (select count(*) from auth.users
      where email in ('916000000102@phone.oasis.local', '916000000103@phone.oasis.local')
      and raw_app_meta_data @> '{"retained":true}'
      and not (raw_app_meta_data ? 'msg91_verified_phone_alias')) <> 2 then
    raise exception 'Trusted provisioning must consume only the authorization';
  end if;

  begin
    insert into auth.users (email, raw_app_meta_data)
      values ('916000000104@phone.oasis.local', '{"msg91_verified_phone_alias":{"email":"916000000105@phone.oasis.local","nonce":"wrong-alias"}}');
    set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;
    raise exception 'Authorization for a different alias was accepted';
  exception when check_violation then
    if sqlerrm <> 'Reserved phone alias requires verified provisioning' then raise; end if;
  end;

  -- A marker left during the deployment window cannot authorize a later edit.
  insert into auth.users (email, raw_app_meta_data)
    values ('stale@example.test', '{"msg91_verified_phone_alias":{"email":"916000000106@phone.oasis.local","nonce":"stale"}}');
  begin
    update auth.users set email = '916000000106@phone.oasis.local'
      where email = 'stale@example.test';
    set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;
    raise exception 'Stale authorization was accepted';
  exception when check_violation then
    if sqlerrm <> 'Reserved phone alias requires fresh verified provisioning' then raise; end if;
  end;
end;
$$;

-- Legacy aliases remain usable without backfilling authorization markers.
update auth.users set email = email, email_confirmed_at = now()
  where email = '916000000100@phone.oasis.local';
set constraints auth.msg91_reserved_phone_alias_guard_v1 immediate;
rollback;
