-- Point 25 clean-replay repair: production contained these role authority
-- tables before Core ownership, but the repository migration chain did not.
-- Additive and idempotent: existing production tables and data are preserved.

create table if not exists public.roles (
  id uuid primary key default gen_random_uuid(),
  role_key text not null unique,
  role_name text not null,
  is_active boolean default true,
  created_at timestamptz default timezone('utc', now())
);

create table if not exists public.user_role_map (
  id uuid primary key default gen_random_uuid(),
  user_id uuid references auth.users(id) on delete cascade,
  role_id uuid references public.roles(id) on delete cascade,
  created_at timestamptz default timezone('utc', now()),
  unique (user_id, role_id)
);

create index if not exists user_role_map_user_id_idx
  on public.user_role_map(user_id);

create index if not exists user_role_map_role_id_idx
  on public.user_role_map(role_id);

alter table public.roles enable row level security;
alter table public.user_role_map enable row level security;

comment on table public.roles is
  'Legacy-compatible global role authority represented in the Core migration chain for deterministic replay.';
comment on table public.user_role_map is
  'Legacy-compatible authenticated-user to global-role mapping represented for deterministic replay.';
