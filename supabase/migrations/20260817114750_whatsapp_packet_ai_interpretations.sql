-- Recovered historical migration: reproduces the exact SQL applied to production
-- (tcxvcatsqqertcnycuop) under this version, fetched read-only via
-- the production migration ledger's statements column during the 2026-08-18
-- production migration lineage recovery. See
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv
-- for provenance (represented by Core PR #82 branch fix/wa-multimodal-hindi-interpretation,
-- normalized-SHA exact match against supabase/migrations/20260817140001_whatsapp_packet_ai_interpretations.sql).
-- This file exists so a clean zero-state replay creates the same schema
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

begin;

create table if not exists public.whatsapp_packet_ai_interpretations (
  id uuid primary key default gen_random_uuid(),
  packet_id uuid not null references public.whatsapp_message_packets(id) on delete restrict,
  content_fingerprint text not null,
  provider_message_ids text[] not null default '{}'::text[],
  interpretation jsonb not null,
  model_version text not null,
  created_at timestamptz not null default now(),
  constraint whatsapp_packet_ai_interpretations_fingerprint_nonempty
    check (length(btrim(content_fingerprint)) > 0),
  constraint whatsapp_packet_ai_interpretations_provider_ids_nonempty
    check (cardinality(provider_message_ids) > 0),
  constraint whatsapp_packet_ai_interpretations_interpretation_object
    check (jsonb_typeof(interpretation) = 'object'),
  unique (packet_id, content_fingerprint)
);

comment on table public.whatsapp_packet_ai_interpretations is
  'Append-only advisory AI interpretations of immutable WhatsApp message packets. Human authority remains required for business commitments.';
comment on column public.whatsapp_packet_ai_interpretations.interpretation is
  'Derived multimodal evidence interpretation only; never authoritative source evidence or execution authority.';

create index if not exists whatsapp_packet_ai_interpretations_packet_created_idx
  on public.whatsapp_packet_ai_interpretations (packet_id, created_at desc);

alter table public.whatsapp_packet_ai_interpretations enable row level security;

revoke all on public.whatsapp_packet_ai_interpretations from anon;
revoke insert, update, delete on public.whatsapp_packet_ai_interpretations from authenticated;
grant select on public.whatsapp_packet_ai_interpretations to authenticated;

create policy whatsapp_packet_ai_interpretations_reader_select
  on public.whatsapp_packet_ai_interpretations
  for select
  to authenticated
  using (public.is_whatsapp_inbox_reader(auth.uid()));

drop trigger if exists whatsapp_packet_ai_interpretations_append_only
  on public.whatsapp_packet_ai_interpretations;
create trigger whatsapp_packet_ai_interpretations_append_only
  before update or delete on public.whatsapp_packet_ai_interpretations
  for each row execute function public.prevent_audit_log_mutation();

commit;
