-- Post-cleanup verification for physical packing activity and auth registration race protection.
-- packing_lists does not carry order_id directly. Validate both supported ownership paths.

-- Archived orders linked through dispatches -> packing_lists must be zero.
select count(*) = 0 as no_archived_orders_on_dispatch_packing_lists
from cleanup_archive.order_snapshot_20260722 archived_order
join public.dispatches dispatch on dispatch.order_id = archived_order.id
join public.packing_lists packing on packing.dispatch_id = dispatch.id;

-- Archived orders linked through order_items -> packing_lists must be zero.
select count(*) = 0 as no_archived_orders_on_item_packing_lists
from cleanup_archive.order_snapshot_20260722 archived_order
join public.order_items item on item.order_id = archived_order.id
join public.packing_lists packing on packing.order_item_id = item.id;

-- Verify the archived auth population did not include accounts created inside the 24-hour safety window.
-- Replace :migration_started_at with the exact migration timestamp when executing future cleanup runs.
select count(*) = 0 as no_recent_archived_auth_users
from cleanup_archive.auth_user_snapshot_20260722 archived_user
where archived_user.created_at >= (:migration_started_at::timestamptz - interval '24 hours');

-- Mandatory future candidate guard:
--   auth.users.created_at < now() - interval '24 hours'
-- This protects accounts in registration, email confirmation, OTP, OAuth, Apple, Google,
-- WhatsApp/msg91 or other multi-step identity flows from quarantine races.
