# Runbook — RLS Team Access

## Symptom

UI says:

```txt
Live messages enabled — no inbound messages yet
```

but SQL shows rows in `whatsapp_inbound_messages`.

## Likely Cause

RLS is hiding rows because:

```sql
public.is_team_member(auth.uid()) = false
```

## Check Users

```sql
select
  au.email,
  public.is_team_member(au.id) as is_team_member
from auth.users au
order by au.email;
```

## Check Role Mappings

```sql
select
  au.email,
  urm.user_id,
  r.role_key,
  r.is_active
from public.user_role_map urm
join public.roles r on r.id = urm.role_id
left join auth.users au on au.id = urm.user_id
order by au.email, r.role_key;
```

## Check Roles

```sql
select
  id,
  role_key,
  is_active
from public.roles
order by role_key;
```

## Add Known User to Super Admin

Use only with owner approval.

```sql
with target_user as (
  select id
  from auth.users
  where email = 'purecocoa@live.in'
),
target_role as (
  select id
  from public.roles
  where role_key = 'super_admin'
    and coalesce(is_active, true)
)
insert into public.user_role_map (user_id, role_id)
select target_user.id, target_role.id
from target_user, target_role
where not exists (
  select 1
  from public.user_role_map urm
  where urm.user_id = target_user.id
    and urm.role_id = target_role.id
);
```

## Rule

Do not remove RLS or change policy to always true. Fix the role mapping.
