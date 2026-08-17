-- Allow trusted service-role packet processors to read immutable commercial
-- evidence and append/read derived packet AI interpretations. Human/browser
-- roles retain their existing restricted authority.

grant select on table public.whatsapp_commercial_evidence to service_role;
grant select, insert on table public.whatsapp_packet_ai_interpretations to service_role;

-- Explicitly preserve the append-only boundary for the trusted processor.
revoke update, delete on table public.whatsapp_commercial_evidence from service_role;
revoke update, delete on table public.whatsapp_packet_ai_interpretations from service_role;

comment on table public.whatsapp_packet_ai_interpretations is
  'Append-only advisory AI interpretations of immutable WhatsApp packets. service_role may append/read derived results; UPDATE/DELETE remain forbidden.';
