# Access Control Ledger

## Purpose

This file records confirmed access-control behavior and required follow-up.

## Confirmed RLS Gate

Operator Inbox read access depends on:

```sql
public.is_team_member(auth.uid())
```

Function definition checks:

```txt
public.user_role_map -> public.roles
```

Allowed role keys:

```txt
super_admin
admin
owner
catalogue_admin
catalogue_manager
operations
sales
```

## Confirmed Users

| Email | is_team_member | Notes |
|---|---:|---|
| `admin@oasisbaklawa.com` | true | super_admin |
| `purecocoa@live.in` | true | fixed by mapping to super_admin |
| `dinesh_mutreja@yahoo.co.in` | false | will see empty Operator Inbox unless mapped |

## Important Lesson

If Operator Inbox shows:

```txt
Live messages enabled — no inbound messages yet
```

while SQL shows rows in `whatsapp_inbound_messages`, check RLS/team mapping before editing frontend filters.

## Suggested Follow-Up

Decide whether to add `dinesh_mutreja@yahoo.co.in` to an allowed role.

Suggested role:

```txt
owner
```

or if only available role is currently:

```txt
super_admin
```

then use `super_admin` after approval.

## Role Expansion Backlog

The roles table may not include all role keys used by `is_team_member`.

If desired, create/activate:

```txt
admin
owner
catalogue_admin
catalogue_manager
operations
sales
```

or update the function to match actual role vocabulary only after reviewing all RLS dependencies.

## Security Rule

Do not loosen RLS to `true` for convenience. Fix user-role mapping instead.
