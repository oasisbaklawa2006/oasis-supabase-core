-- Behavioral acceptance for governed WhatsApp operator workspace deletion.
begin;
select plan(12);

insert into auth.users (id, email) values
  ('88000000-0000-0000-0000-000000000001', 'waop-delete-admin@example.test');
insert into public.users (id, email, name, role, is_active) values
  ('88000000-0000-0000-0000-000000000001', 'waop-delete-admin@example.test', 'WAOP Delete Admin', 'admin', true);
insert into public.user_role_map (user_id, role_id)
select '88000000-0000-0000-0000-000000000001'::uuid, r.id
from public.roles r
where r.role_key = 'admin';

insert into public.whatsapp_contacts (id, phone_number, customer_name) values
  ('88000000-0000-0000-0000-000000000010', '919555555555', 'WAOP Delete Contact');
insert into public.whatsapp_message_packets (
  id, contact_id, stitched_content, first_message_at, last_message_at
) values
  ('88000000-0000-0000-0000-000000000020', '88000000-0000-0000-0000-000000000010', '{}'::jsonb, now(), now()),
  ('88000000-0000-0000-0000-000000000021', '88000000-0000-0000-0000-000000000010', '{}'::jsonb, now(), now());

select set_config(
  'request.jwt.claims',
  json_build_object('sub', '88000000-0000-0000-0000-000000000001', 'role', 'authenticated', 'aal', 'aal1')::text,
  true
);
set local role authenticated;

select lives_ok(
  $$select public.upsert_whatsapp_operator_note(
      '88000000-0000-0000-0000-000000000020',
      'Delete me',
      'waop-delete-note-seed'
    )$$,
  'operator seeds packet note'
);
select lives_ok(
  $$select public.delete_whatsapp_operator_note(
      '88000000-0000-0000-0000-000000000020',
      'waop-delete-note-1'
    )$$,
  'operator deletes own packet note'
);
select is(
  (select count(*) from public.whatsapp_operator_packet_notes
    where packet_id = '88000000-0000-0000-0000-000000000020'
      and actor_id = '88000000-0000-0000-0000-000000000001'),
  0::bigint,
  'deleted note no longer hydrates as active workspace state'
);
select lives_ok(
  $$select public.delete_whatsapp_operator_note(
      '88000000-0000-0000-0000-000000000020',
      'waop-delete-note-1'
    )$$,
  'note delete replay is idempotent'
);
select throws_ok(
  $$select public.delete_whatsapp_operator_note(
      '88000000-0000-0000-0000-000000000021',
      'waop-delete-note-1'
    )$$,
  'WA_OPERATOR_IDEMPOTENCY_KEY_REUSE_MISMATCH',
  'note delete key cannot be reused for another packet'
);

select lives_ok(
  $$select public.save_whatsapp_operator_view(
      'delete-me',
      'Delete me',
      '{"unansweredOnly":true}'::jsonb,
      'waop-delete-view-seed'
    )$$,
  'operator seeds saved view'
);
select lives_ok(
  $$select public.delete_whatsapp_operator_view(
      'delete-me',
      'waop-delete-view-1'
    )$$,
  'operator deletes own saved view'
);
select is(
  (select count(*) from public.whatsapp_operator_saved_views
    where owner_user_id = '88000000-0000-0000-0000-000000000001'
      and view_key = 'delete-me'),
  0::bigint,
  'deleted saved view no longer hydrates as active workspace state'
);
select lives_ok(
  $$select public.delete_whatsapp_operator_view(
      'delete-me',
      'waop-delete-view-1'
    )$$,
  'saved-view delete replay is idempotent'
);
select throws_ok(
  $$select public.delete_whatsapp_operator_view(
      'different-view',
      'waop-delete-view-1'
    )$$,
  'WA_OPERATOR_IDEMPOTENCY_KEY_REUSE_MISMATCH',
  'saved-view delete key cannot be reused for another target'
);

select is(
  (select count(*) from public.whatsapp_operator_workspace_deletions
    where actor_id = '88000000-0000-0000-0000-000000000001'
      and object_kind = 'PACKET_NOTE'
      and idempotency_key = 'waop-delete-note-1'),
  1::bigint,
  'note deletion has exactly one audit receipt'
);
select is(
  (select count(*) from public.whatsapp_operator_workspace_deletions
    where actor_id = '88000000-0000-0000-0000-000000000001'
      and object_kind = 'SAVED_VIEW'
      and idempotency_key = 'waop-delete-view-1'),
  1::bigint,
  'saved-view deletion has exactly one audit receipt'
);

select * from finish();
rollback;
