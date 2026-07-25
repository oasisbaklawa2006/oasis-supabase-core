-- Contracts for:
-- 20260725150000_wa_canonical_communication_case_foundation
-- 20260725173000_wa_case_accountability_and_handoffs
-- 20260725180000_wa_case_formal_clarification
-- 20260725200000_wa_case_outbound_communication_governance
-- 20260725210000_wa_case_lifecycle_consent_and_closure
-- 20260725220000_wa_case_sensitive_intake_and_manual_queues
-- 20260725230000_wa_final_reconciliation_and_retirement
begin;

select plan(1);

do $$
declare
  required_table text;
begin
  foreach required_table in array array[
    'whatsapp_communication_cases',
    'whatsapp_case_identities',
    'whatsapp_case_requested_lines',
    'whatsapp_case_interpretations',
    'whatsapp_case_proposed_changes',
    'whatsapp_case_confirmations',
    'whatsapp_case_events',
    'whatsapp_case_department_tasks',
    'whatsapp_case_handoffs',
    'whatsapp_case_escalations',
    'whatsapp_case_clarifications',
    'whatsapp_case_clarification_followups',
    'whatsapp_case_recipient_authorizations',
    'whatsapp_case_outbound_decisions',
    'whatsapp_case_outbound_attempts',
    'whatsapp_case_reply_validations',
    'whatsapp_communication_preferences',
    'whatsapp_case_milestone_events',
    'whatsapp_case_closures',
    'whatsapp_case_manual_assignments',
    'whatsapp_case_payment_proofs',
    'whatsapp_case_restricted_evidence',
    'whatsapp_case_channel_migrations',
    'whatsapp_replay_runs',
    'whatsapp_replay_results',
    'whatsapp_reconciliation_runs',
    'whatsapp_reconciliation_exceptions',
    'whatsapp_learning_candidates',
    'whatsapp_legacy_capability_retirements'
  ] loop
    if to_regclass('public.' || required_table) is null then
      raise exception 'required WhatsApp programme table public.% is missing', required_table;
    end if;

    if not exists (
      select 1
      from pg_class
      where oid = to_regclass('public.' || required_table)
        and relrowsecurity
    ) then
      raise exception 'RLS is not enabled on public.%', required_table;
    end if;
  end loop;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.whatsapp_case_events'::regclass
      and tgname = 'trg_whatsapp_case_events_no_mutation'
      and tgenabled <> 'D'
  ) then
    raise exception 'case-event append-only protection is missing';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.whatsapp_legacy_capability_retirements'::regclass
      and tgname = 'trg_whatsapp_legacy_capability_retirements_no_update'
      and tgenabled <> 'D'
  ) then
    raise exception 'legacy-retirement update protection is missing';
  end if;

  if not exists (
    select 1
    from pg_trigger
    where tgrelid = 'public.whatsapp_reconciliation_exceptions'::regclass
      and tgname = 'trg_whatsapp_reconciliation_exceptions_guard'
      and tgenabled <> 'D'
  ) then
    raise exception 'reconciliation-exception sign-off guard is missing';
  end if;
end $$;

select ok(true, 'WhatsApp communication-case programme contracts hold');
select * from finish();
rollback;
