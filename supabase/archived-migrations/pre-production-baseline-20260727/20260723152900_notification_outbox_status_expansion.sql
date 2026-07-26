-- Expand the legacy notification outbox status contract before Point 21 quarantines stale rows.
alter table public.notification_outbox
  drop constraint if exists notification_outbox_status_check;

alter table public.notification_outbox
  add constraint notification_outbox_status_check
  check (status in ('pending','processing','sent','retry','failed','quarantined','cancelled'));