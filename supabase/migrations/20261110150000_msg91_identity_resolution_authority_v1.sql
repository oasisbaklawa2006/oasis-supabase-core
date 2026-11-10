-- PR #522 / issue #521: database-authoritative MSG91 identity resolution.
--
-- The msg91-otp Edge function previously resolved a verified phone with several
-- independent PostgREST requests (candidate scans, a keyset secondary-phone scan)
-- and an unbounded auth.admin.listUsers() recovery scan. Separate requests cannot
-- observe a consistent snapshot, so concurrent inserts could be missed, and the
-- scans fail closed (outage) once the user populations grow.
--
-- This migration adds two service_role-only RPCs that perform the whole decision
-- in ONE transaction, serialised per canonical phone with transaction-level
-- advisory locks, using indexed canonical-phone lookups:
--   * resolve_msg91_identity_v1: read-only identity + Auth-orphan classification.
--   * bind_msg91_pending_profile_v1: atomic check-and-insert of the PENDING
--     public.users row for a verified Auth identity.
-- Neither function mutates auth.users, deletes anything, or widens any grant.
-- The existing B2B placeholder inspect/reconcile RPCs are NOT modified; they take
-- the 'b2b_pending_phone:' advisory lock, which these functions also take (in a
-- fixed order: msg91 lock first) so the two authorities serialise per phone. The B2B access-claim
-- writers' 'b2b_identity_mobile:' lock is taken last, for the same reason.

-- ---------------------------------------------------------------------------
-- Canonical Indian phone: byte-for-byte the same policy as
-- supabase/functions/msg91-otp/strict-phone-match.mjs canonicalIndianPhone().
-- Unlike normalize_b2b_access_mobile_v2 it returns NULL (never a partial or
-- foreign number) for anything that is not an Indian mobile number.
-- ---------------------------------------------------------------------------
create or replace function public.msg91_canonical_indian_phone_v1(p_phone text)
returns text
language sql
immutable
strict
parallel safe
set search_path = pg_catalog
as $$
  select case
    when length(d) = 10 and d ~ '^[6-9]' then '91' || d
    when length(d) = 11 and d ~ '^0[6-9]' then '91' || substr(d, 2)
    when length(d) = 12 and d ~ '^91[6-9]' then d
    else null
  end
  from (select regexp_replace(p_phone, '[^0-9]', '', 'g') as d) s
$$;

create or replace function public.msg91_canonical_phones_v1(p_phones text[])
returns text[]
language sql
immutable
strict
parallel safe
set search_path = pg_catalog
as $$
  select coalesce(array_agg(distinct c) filter (where c is not null), array[]::text[])
  from (
    select public.msg91_canonical_indian_phone_v1(x) as c
    from unnest(p_phones) as x
  ) s
$$;

-- These two helpers are pure, immutable string functions with no table access. They are used by
-- expression indexes on public.users, public.b2b_applications and public.companies, and PostgreSQL
-- requires the WRITING role to hold EXECUTE on an index-expression function when it maintains the
-- index. Without this grant any anon/authenticated INSERT or UPDATE that touches an indexed phone
-- column fails with "permission denied for function". Only the helpers are granted; the identity
-- RPCs below remain service_role-only.
revoke all on function public.msg91_canonical_indian_phone_v1(text) from public;
revoke all on function public.msg91_canonical_phones_v1(text[]) from public;
grant execute on function public.msg91_canonical_indian_phone_v1(text) to anon, authenticated, service_role;
grant execute on function public.msg91_canonical_phones_v1(text[]) to anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Canonical-phone expression indexes so identity lookup is an index probe, not a
-- table scan with per-row function evaluation.
-- ---------------------------------------------------------------------------
create index if not exists users_msg91_canonical_phone_idx
  on public.users (public.msg91_canonical_indian_phone_v1(phone));
create index if not exists users_msg91_canonical_mobile_idx
  on public.users (public.msg91_canonical_indian_phone_v1(mobile_number));
create index if not exists users_msg91_canonical_secondary_idx
  on public.users using gin (public.msg91_canonical_phones_v1(secondary_phones));
create index if not exists users_company_id_msg91_idx
  on public.users (company_id) where company_id is not null;
create index if not exists b2b_applications_msg91_contact_phone_idx
  on public.b2b_applications (public.msg91_canonical_indian_phone_v1(contact_phone));
create index if not exists b2b_applications_msg91_mobile_idx
  on public.b2b_applications (public.msg91_canonical_indian_phone_v1(mobile_number));
create index if not exists companies_msg91_canonical_phone_idx
  on public.companies (public.msg91_canonical_indian_phone_v1(phone));

-- ---------------------------------------------------------------------------
-- resolve_msg91_identity_v1
-- ---------------------------------------------------------------------------
-- Returns one jsonb object:
--   status: phone_invalid | duplicate_phone_identity | ambiguous_phone_identity
--           | existing | none
--   public_user_id            (status = existing)
--   approved_b2b_pending_claim boolean
--   auth_internal_email_user_id / auth_phone_user_id (uuid or null)
--   auth_state: absent | orphan_recoverable | conflict   (status = none only)
--   auth_user_id              (auth_state = orphan_recoverable)
--
-- An Auth identity is recoverable ONLY when it carries the deterministic internal
-- email AND a provider-confirmed phone equal to the verified phone AND a confirmed
-- email, and owns no other identifier. Anything else is a conflict: an email-only
-- or unconfirmed Auth row could have been pre-registered by a third party who
-- knows the deterministic email, and must never be handed a session.
create or replace function public.resolve_msg91_identity_v1(p_verified_phone text)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'auth', 'pg_temp'
as $$
declare
  v_phone text := public.msg91_canonical_indian_phone_v1(coalesce(p_verified_phone, ''));
  v_email text;
  v_user_ids uuid[];
  v_company_ids uuid[];
  v_member_count integer;
  v_pending_claim boolean;
  v_email_ids uuid[];
  v_phone_ids uuid[];
  v_email_owner uuid;
  v_phone_owner uuid;
  v_auth_state text;
  v_auth record;
begin
  if v_phone is null then
    return jsonb_build_object('status', 'phone_invalid');
  end if;
  v_email := v_phone || '@phone.oasis.local';

  -- Lock order is fixed: msg91 -> placeholder reconcile -> B2B claim. The claim functions
  -- (claim_approved_b2b_access_request_v2 and its predecessors) take b2b_identity_email then
  -- b2b_identity_mobile and then insert/update public.users.phone; taking the same mobile lock here
  -- serialises this authority against those writers. No other path takes these locks in a
  -- conflicting order (claim never takes the msg91 or placeholder locks).
  perform pg_advisory_xact_lock(hashtextextended('msg91_identity:' || v_phone, 0));
  perform pg_advisory_xact_lock(hashtextextended('b2b_pending_phone:' || v_phone, 0));
  perform pg_advisory_xact_lock(hashtextextended('b2b_identity_mobile:' || v_phone, 0));

  select coalesce(array_agg(u.id order by u.id), array[]::uuid[])
    into v_user_ids
  from public.users u
  where public.msg91_canonical_indian_phone_v1(u.phone) = v_phone
     or public.msg91_canonical_indian_phone_v1(u.mobile_number) = v_phone
     or public.msg91_canonical_phones_v1(u.secondary_phones) @> array[v_phone];

  select coalesce(array_agg(distinct a.resolved_company_id) filter (where a.resolved_company_id is not null), array[]::uuid[]),
         coalesce(bool_or(a.user_id is null or a.user_id <> all (v_user_ids)), false)
    into v_company_ids, v_pending_claim
  from public.b2b_applications a
  where a.status = 'approved'
    and (public.msg91_canonical_indian_phone_v1(a.contact_phone) = v_phone
         or public.msg91_canonical_indian_phone_v1(a.mobile_number) = v_phone);

  select v_company_ids || coalesce(array_agg(c.id), array[]::uuid[])
    into v_company_ids
  from public.companies c
  where public.msg91_canonical_indian_phone_v1(c.phone) = v_phone;

  select count(*) into v_member_count
  from public.users u
  where u.company_id = any (v_company_ids);

  select coalesce(array_agg(au.id), array[]::uuid[]) into v_email_ids
  from auth.users au where au.email = v_email;
  select coalesce(array_agg(au.id), array[]::uuid[]) into v_phone_ids
  from auth.users au where au.phone in (v_phone, '+' || v_phone);
  v_email_owner := case when cardinality(v_email_ids) = 1 then v_email_ids[1] end;
  v_phone_owner := case when cardinality(v_phone_ids) = 1 then v_phone_ids[1] end;

  if cardinality(v_user_ids) > 1 then
    return jsonb_build_object('status', 'duplicate_phone_identity');
  end if;

  if cardinality(v_user_ids) = 0 and v_member_count > 0 and not v_pending_claim then
    return jsonb_build_object('status', 'ambiguous_phone_identity');
  end if;

  if cardinality(v_user_ids) = 1 then
    return jsonb_build_object(
      'status', 'existing',
      'public_user_id', v_user_ids[1],
      'approved_b2b_pending_claim', v_pending_claim,
      'auth_internal_email_user_id', v_email_owner,
      'auth_phone_user_id', v_phone_owner,
      'auth_identifier_ambiguous', cardinality(v_email_ids) > 1 or cardinality(v_phone_ids) > 1
    );
  end if;

  -- No public identity: classify any pre-existing Auth identity (orphan recovery).
  if cardinality(v_email_ids) = 0 and cardinality(v_phone_ids) = 0 then
    v_auth_state := 'absent';
  elsif cardinality(v_email_ids) = 1 and cardinality(v_phone_ids) = 1 and v_email_owner = v_phone_owner then
    select au.id, au.phone, au.phone_confirmed_at, au.email_confirmed_at
      into v_auth
    from auth.users au where au.id = v_email_owner;
    if public.msg91_canonical_indian_phone_v1(coalesce(v_auth.phone, '')) = v_phone
       and v_auth.phone_confirmed_at is not null
       and v_auth.email_confirmed_at is not null then
      v_auth_state := 'orphan_recoverable';
    else
      v_auth_state := 'conflict';
    end if;
  else
    v_auth_state := 'conflict';
  end if;

  return jsonb_build_object(
    'status', 'none',
    'approved_b2b_pending_claim', v_pending_claim,
    'auth_internal_email_user_id', v_email_owner,
    'auth_phone_user_id', v_phone_owner,
    'auth_state', v_auth_state,
    'auth_user_id', case when v_auth_state = 'orphan_recoverable' then v_email_owner end
  );
end;
$$;

revoke all on function public.resolve_msg91_identity_v1(text) from public, anon, authenticated;
grant execute on function public.resolve_msg91_identity_v1(text) to service_role;

comment on function public.resolve_msg91_identity_v1(text) is
  'Service-only, read-only MSG91 identity resolution after provider phone verification. Single-transaction, per-phone advisory-locked, indexed canonical-phone matching across users/b2b_applications/companies plus deterministic-email Auth orphan classification. Returns a status object; never mutates state and never returns other users'' identifiers except the single matched user id.';

-- ---------------------------------------------------------------------------
-- bind_msg91_pending_profile_v1
-- ---------------------------------------------------------------------------
-- Atomic check-and-insert. Re-resolves the identity inside the same locked
-- transaction so a concurrent writer cannot create a second public identity for
-- the phone between the Edge function's lookup and this insert.
-- Returns jsonb { status }: created | exists | auth_identity_invalid |
-- public_identity_conflict.
create or replace function public.bind_msg91_pending_profile_v1(
  p_verified_phone text,
  p_auth_user_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = 'public', 'auth', 'pg_temp'
as $$
declare
  v_phone text := public.msg91_canonical_indian_phone_v1(coalesce(p_verified_phone, ''));
  v_res jsonb;
begin
  if v_phone is null then
    return jsonb_build_object('status', 'phone_invalid');
  end if;
  if p_auth_user_id is null then
    return jsonb_build_object('status', 'auth_identity_invalid');
  end if;

  -- Re-entrant within this transaction: resolve takes the same locks.
  v_res := public.resolve_msg91_identity_v1(v_phone);

  if v_res ->> 'status' = 'existing' then
    if (v_res ->> 'public_user_id')::uuid = p_auth_user_id then
      return jsonb_build_object('status', 'exists');
    end if;
    return jsonb_build_object('status', 'public_identity_conflict');
  end if;

  if v_res ->> 'status' <> 'none' then
    return jsonb_build_object('status', 'public_identity_conflict');
  end if;

  if v_res ->> 'auth_state' <> 'orphan_recoverable'
     or (v_res ->> 'auth_user_id')::uuid <> p_auth_user_id then
    return jsonb_build_object('status', 'auth_identity_invalid');
  end if;

  -- A row with this id but no phone binding is an identity we cannot silently adopt.
  if exists (select 1 from public.users u where u.id = p_auth_user_id) then
    return jsonb_build_object('status', 'public_identity_conflict');
  end if;

  insert into public.users (id, role, phone)
  values (p_auth_user_id, 'PENDING', '+' || v_phone);

  return jsonb_build_object('status', 'created');
end;
$$;

revoke all on function public.bind_msg91_pending_profile_v1(text, uuid) from public, anon, authenticated;
grant execute on function public.bind_msg91_pending_profile_v1(text, uuid) to service_role;

comment on function public.bind_msg91_pending_profile_v1(text, uuid) is
  'Service-only atomic creation of the non-privileged PENDING public.users row for a provider-verified, Auth-confirmed phone identity. Re-resolves under the per-phone advisory lock; refuses if any other public identity, ambiguity or non-matching Auth identity exists. Idempotent for the same Auth user.';
