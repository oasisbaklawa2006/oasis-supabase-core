\set ON_ERROR_STOP on

-- Fail-closed rollback for a failed packet-AI runtime certification. The Edge
-- Function may remain deployed, but the cron target becomes inert because its
-- governed URL authority is blanked. The machine secret is never read or changed.

begin;

select vault.update_secret(
  secret_id,
  '',
  'whatsapp_packet_ai_consumer_url_v1',
  'DISABLED after failed WhatsApp packet AI consumer runtime certification',
  null
)
from (
  select id as secret_id
  from vault.decrypted_secrets
  where name = 'whatsapp_packet_ai_consumer_url_v1'
  order by created_at desc
  limit 1
) existing;

commit;

select case
  when coalesce((
    select decrypted_secret
    from vault.decrypted_secrets
    where name = 'whatsapp_packet_ai_consumer_url_v1'
    order by created_at desc
    limit 1
  ), '') = '' then 'scheduler_inert'
  else 'rollback_failed'
end as rollback_state;
