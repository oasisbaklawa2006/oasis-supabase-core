-- TEST-ONLY minimal schema stub for msg91_identity_authority.test.mjs.
-- It models only the columns the identity authority and the pre-existing B2B
-- placeholder RPCs read. It is NOT a replacement for the real baseline; the same
-- migration is additionally validated against the migration-backed Preview.
create extension if not exists pgcrypto;
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
end $$;
create schema if not exists auth;
create table auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  phone text,
  phone_confirmed_at timestamptz,
  email_confirmed_at timestamptz,
  is_sso_user boolean not null default false
);
create unique index users_email_partial_key on auth.users (email) where is_sso_user = false;
create unique index users_phone_key on auth.users (phone);
-- Mirrors the real Supabase auth.users index set (a full, non-partial email btree exists alongside the partial unique key).
create index idx_users_email on auth.users (email);
create table public.companies (id uuid primary key default gen_random_uuid(), phone text, account_manager_id uuid);
create table public.users (
  id uuid primary key default gen_random_uuid(),
  company_id uuid, name text, email text, phone text, role text not null,
  full_name text, mobile_number text, department text, designation text,
  is_active boolean default true, invite_status text default 'active',
  preferred_language text default 'en', is_sales_executive boolean not null default false,
  secondary_phones text[] default array[]::text[], deleted_at timestamptz
);
create table public.b2b_applications (
  id uuid primary key default gen_random_uuid(), status text, user_id uuid,
  resolved_company_id uuid, contact_phone text, mobile_number text,
  created_at timestamptz default now(), reviewed_at timestamptz
);
create table public.profiles (id uuid primary key);
create table public.user_role_map (id uuid primary key default gen_random_uuid(), user_id uuid);
create table public.audit_logs (
  id uuid primary key default gen_random_uuid(), action_type text, module_name text, entity_name text,
  entity_id text, actor_id uuid, reason text, old_value jsonb, new_value jsonb, risk_level text
);
create function public.is_internal_staff(p uuid) returns boolean language sql as $$ select false $$;

-- Writer-role privileges so the tests can prove index maintenance works for non-owner roles.
grant usage on schema public to anon, authenticated, service_role;
grant select, insert, update, delete on public.users, public.b2b_applications, public.companies to anon, authenticated, service_role;
