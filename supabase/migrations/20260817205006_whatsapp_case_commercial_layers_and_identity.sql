-- Recovered historical migration: reproduces the production semantics applied to
-- production (tcxvcatsqqertcnycuop) under this version, per
-- docs/reconciliation/production-migration-ledger-remote-history-2026-08-18.csv:
-- represented by Core PR #84 supabase/migrations/20260818010500_whatsapp_case_commercial_layers_and_identity.sql (head 3b013b4); comment/whitespace-only delta consistent with pattern.
-- This file exists so a clean zero-state replay creates the same schema/functions
-- production already has, under the version production already recognizes as
-- applied -- it must not execute a second time against production.

-- Activate the pre-existing requested / interpreted / proposed / confirmed case model
-- without creating a parallel commercial authority. Packet AI may materialize advisory
-- interpretation layers from immutable evidence; humans remain the only authority for
-- identity confirmation, proposed-change decisions and accountable handoffs.

create or replace function public.materialize_whatsapp_case_ai_layers_from_event()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_case public.whatsapp_communication_cases%rowtype;
  v_ai public.whatsapp_packet_ai_interpretations%rowtype;
  v_interpretation_id uuid;
  v_lines jsonb;
  v_line jsonb;
  v_idx integer;
  v_source_ids uuid[];
  v_verbatim text;
  v_old_ids uuid[];
  v_old_id uuid;
  v_requested public.whatsapp_case_requested_lines%rowtype;
  v_quantity numeric;
  v_unit text;
  v_product_text text;
  v_status text;
  v_unresolved text[];
  v_confidence numeric;
  v_materialized integer := 0;
begin
  if new.event_type <> 'AI_CONCLUSION_READY'
     or new.actor_type <> 'SYSTEM'
     or new.actor_id is not null then
    return new;
  end if;

  begin
    v_interpretation_id := nullif(new.metadata ->> 'packet_ai_interpretation_id','')::uuid;
  exception when others then
    return new;
  end;
  if v_interpretation_id is null then return new; end if;

  select * into v_case from public.whatsapp_communication_cases where id=new.case_id;
  if not found then return new; end if;
  select * into v_ai
  from public.whatsapp_packet_ai_interpretations
  where id=v_interpretation_id and packet_id=v_case.packet_id;
  if not found then return new; end if;

  v_lines := case
    when jsonb_typeof(v_ai.interpretation #> '{conclusion,order_lines}')='array'
      then v_ai.interpretation #> '{conclusion,order_lines}'
    else '[]'::jsonb
  end;
  if jsonb_array_length(v_lines)=0 then return new; end if;

  select coalesce(array_agg(id order by line_number),'{}'::uuid[])
  into v_old_ids
  from public.whatsapp_case_requested_lines
  where case_id=v_case.id and superseded_at is null;

  v_confidence := case when jsonb_typeof(v_ai.interpretation->'confidence')='number'
    then least(1::numeric,greatest(0::numeric,(v_ai.interpretation->>'confidence')::numeric))
    else 0::numeric end;

  for v_line,v_idx in
    select value,ordinality::integer
    from jsonb_array_elements(v_lines) with ordinality
  loop
    if jsonb_typeof(v_line->'evidence_ids') <> 'array' then continue; end if;

    select coalesce(array_agg(m.id order by m.packet_sequence nulls last,m.created_at,m.id),'{}'::uuid[]),
           string_agg(coalesce(nullif(btrim(m.content),''),'['||coalesce(m.message_type,'evidence')||' evidence]'), E'\n'
             order by m.packet_sequence nulls last,m.created_at,m.id)
    into v_source_ids,v_verbatim
    from public.whatsapp_messages m
    where m.packet_id=v_case.packet_id
      and m.direction='inbound'
      and m.provider_message_id in (select jsonb_array_elements_text(v_line->'evidence_ids'));

    -- An AI line without packet evidence is never promoted into the customer-requested layer.
    if cardinality(v_source_ids)=0 or nullif(btrim(coalesce(v_verbatim,'')),'') is null then continue; end if;

    v_old_id := case when cardinality(v_old_ids)>=v_idx then v_old_ids[v_idx] else null end;
    v_product_text := nullif(btrim(coalesce(v_line->>'product_name','')),'');
    v_quantity := case when jsonb_typeof(v_line->'quantity')='number' and (v_line->>'quantity')::numeric>0
      then (v_line->>'quantity')::numeric else null end;
    v_unit := nullif(btrim(coalesce(v_line->>'unit','')),'');
    v_status := lower(btrim(coalesce(v_line->>'status','unclear')));
    v_unresolved := array_remove(array[
      case when v_product_text is null then 'product' end,
      case when v_quantity is null then 'quantity' end,
      case when v_quantity is not null and v_unit is null then 'unit' end
    ],null);

    insert into public.whatsapp_case_requested_lines(
      case_id,line_number,source_message_ids,verbatim_request,product_text,quantity_text,unit_text,
      correction_of_line_id
    ) values (
      v_case.id,
      coalesce((select max(line_number) from public.whatsapp_case_requested_lines where case_id=v_case.id),0)+1,
      v_source_ids,v_verbatim,null,null,null,v_old_id
    ) returning * into v_requested;

    insert into public.whatsapp_case_interpretations(
      requested_line_id,version,product_id,quantity,unit,packaging,required_date,instructions,
      unresolved_fields,confidence,inference_source,model_or_rule_version,evidence,created_by
    ) values (
      v_requested.id,1,null,v_quantity,v_unit,null,null,null,
      v_unresolved,
      case when v_status='explicit' then v_confidence when v_status='interpreted' then least(v_confidence,0.85) else least(v_confidence,0.50) end,
      'AI',coalesce(nullif(v_ai.model_version,''),'packet-ai-b2b-v1'),
      jsonb_build_object(
        'packet_ai_interpretation_id',v_ai.id,
        'status',v_status,
        'normalized_product_text',v_product_text,
        'evidence_provider_message_ids',v_line->'evidence_ids',
        'source_message_ids',to_jsonb(v_source_ids),
        'ai_line',v_line
      ),null
    );
    v_materialized := v_materialized+1;
  end loop;

  if v_materialized>0 and cardinality(v_old_ids)>0 then
    update public.whatsapp_case_requested_lines
    set superseded_at=coalesce(superseded_at,statement_timestamp())
    where id=any(v_old_ids) and superseded_at is null;
  end if;
  return new;
end;
$$;

revoke all on function public.materialize_whatsapp_case_ai_layers_from_event() from public,anon,authenticated,service_role;

drop trigger if exists whatsapp_case_ai_layers_after_conclusion on public.whatsapp_case_events;
create trigger whatsapp_case_ai_layers_after_conclusion
after insert on public.whatsapp_case_events
for each row when (new.event_type='AI_CONCLUSION_READY' and new.actor_type='SYSTEM')
execute function public.materialize_whatsapp_case_ai_layers_from_event();


create or replace function public.whatsapp_confirm_original_communicator(
  p_case_id uuid,
  p_party_type text,
  p_party_id uuid,
  p_display_label text,
  p_phone_e164 text,
  p_verification_method text,
  p_evidence jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_identity public.whatsapp_case_identities%rowtype;
  v_party_type text:=upper(btrim(coalesce(p_party_type,'')));
  v_label text:=btrim(coalesce(p_display_label,''));
  v_method text:=upper(btrim(coalesce(p_verification_method,'')));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.triage') then
    raise exception 'WhatsApp triage permission required' using errcode='42501';
  end if;
  if v_party_type not in ('EMPLOYEE','CUSTOMER','CONTACT','COMPANY','UNKNOWN') then raise exception 'invalid original communicator party type'; end if;
  if v_party_type<>'UNKNOWN' and p_party_id is null then raise exception 'identified original communicator requires party id'; end if;
  if length(v_label)<2 or length(v_label)>300 then raise exception 'original communicator display label required'; end if;
  if v_method not in ('DIRECT_MESSAGE','FORWARDED_MESSAGE','CALLBACK','EMPLOYEE_REPORT','CUSTOMER_NOMINATED','OPERATOR_VERIFIED') then raise exception 'unsupported original communicator verification method'; end if;
  if p_evidence is null or jsonb_typeof(p_evidence)<>'object' or p_evidence='{}'::jsonb then raise exception 'original communicator evidence required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case identity cannot be changed'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='original-communicator:'||v_key) then
    select * into v_identity from public.whatsapp_case_identities where case_id=p_case_id and identity_role='ORIGINAL_COMMUNICATOR';
    return jsonb_build_object('case_id',p_case_id,'identity_id',v_identity.id,'idempotent_replay',true);
  end if;

  insert into public.whatsapp_case_identities(
    case_id,identity_role,party_type,party_id,display_label,phone_e164,resolution_status,confidence,resolved_by,resolved_at,evidence
  ) values (
    p_case_id,'ORIGINAL_COMMUNICATOR',v_party_type,p_party_id,v_label,nullif(btrim(coalesce(p_phone_e164,'')),''),
    'CONFIRMED',1.0,v_actor,statement_timestamp(),jsonb_build_array(p_evidence||jsonb_build_object('verification_method',v_method))
  )
  on conflict(case_id,identity_role) do update
  set party_type=excluded.party_type,party_id=excluded.party_id,display_label=excluded.display_label,
      phone_e164=excluded.phone_e164,resolution_status='CONFIRMED',confidence=1.0,resolved_by=v_actor,
      resolved_at=statement_timestamp(),evidence=public.whatsapp_case_identities.evidence||excluded.evidence
  returning * into v_identity;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'ORIGINAL_COMMUNICATOR_CONFIRMED',v_actor,'OPERATOR','original-communicator:'||v_key,
    jsonb_build_object('identity_id',v_identity.id,'party_type',v_identity.party_type,'party_id',v_identity.party_id),
    jsonb_build_object('verification_method',v_method,'human_authority',true));

  return jsonb_build_object('case_id',p_case_id,'identity_id',v_identity.id,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_confirm_original_communicator(uuid,text,uuid,text,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_confirm_original_communicator(uuid,text,uuid,text,text,text,jsonb,text) to authenticated;


create or replace function public.whatsapp_propose_case_change(
  p_case_id uuid,
  p_interpretation_id uuid,
  p_change_type text,
  p_requested_value jsonb,
  p_proposed_value jsonb,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_change public.whatsapp_case_proposed_changes%rowtype;
  v_type text:=upper(btrim(coalesce(p_change_type,'')));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.draft.manage') then
    raise exception 'WhatsApp draft management permission required' using errcode='42501';
  end if;
  if v_type not in ('PRODUCT_SUBSTITUTION','QUANTITY','UNIT','PACKAGING','PRICE','DELIVERY_DATE','DELIVERY_LOCATION','OTHER') then raise exception 'unsupported proposed change type'; end if;
  if p_proposed_value is null then raise exception 'proposed value required'; end if;
  if length(v_reason)<5 or length(v_reason)>1000 then raise exception 'proposal reason required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;
  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot receive proposal'; end if;
  if p_interpretation_id is not null and not exists(
    select 1 from public.whatsapp_case_interpretations i join public.whatsapp_case_requested_lines r on r.id=i.requested_line_id
    where i.id=p_interpretation_id and r.case_id=p_case_id
  ) then raise exception 'interpretation does not belong to case'; end if;

  if exists(select 1 from public.whatsapp_case_events where case_id=p_case_id and correlation_key='proposal:'||v_key) then
    select pc.* into v_change from public.whatsapp_case_proposed_changes pc
    join public.whatsapp_case_events e on e.case_id=pc.case_id
    where e.case_id=p_case_id and e.correlation_key='proposal:'||v_key and pc.id=(e.metadata->>'proposed_change_id')::uuid limit 1;
    return jsonb_build_object('case_id',p_case_id,'proposed_change_id',v_change.id,'idempotent_replay',true);
  end if;

  insert into public.whatsapp_case_proposed_changes(
    case_id,interpretation_id,change_type,requested_value,proposed_value,reason,authority_status,proposed_by
  ) values (
    p_case_id,p_interpretation_id,v_type,coalesce(p_requested_value,'null'::jsonb),p_proposed_value,v_reason,'REQUIRES_APPROVAL',v_actor
  ) returning * into v_change;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(p_case_id,'CASE_CHANGE_PROPOSED',v_actor,'OPERATOR','proposal:'||v_key,
    jsonb_build_object('proposed_change_id',v_change.id,'authority_status',v_change.authority_status),
    jsonb_build_object('proposed_change_id',v_change.id,'change_type',v_type,'reason',v_reason));
  return jsonb_build_object('case_id',p_case_id,'proposed_change_id',v_change.id,'authority_status',v_change.authority_status,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_propose_case_change(uuid,uuid,text,jsonb,jsonb,text,text) from public,anon,authenticated;
grant execute on function public.whatsapp_propose_case_change(uuid,uuid,text,jsonb,jsonb,text,text) to authenticated;


create or replace function public.whatsapp_decide_case_proposed_change(
  p_change_id uuid,
  p_decision text,
  p_source_message_id uuid,
  p_authority_reference text,
  p_reason text,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_change public.whatsapp_case_proposed_changes%rowtype;
  v_case public.whatsapp_communication_cases%rowtype;
  v_message public.whatsapp_messages%rowtype;
  v_identity public.whatsapp_case_identities%rowtype;
  v_decision text:=upper(btrim(coalesce(p_decision,'')));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_authority text:=btrim(coalesce(p_authority_reference,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
  v_version integer;
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.draft.manage') then
    raise exception 'WhatsApp draft management permission required' using errcode='42501';
  end if;
  if v_decision not in ('OPERATOR_APPROVED','CUSTOMER_APPROVED','REJECTED') then raise exception 'invalid proposed change decision'; end if;
  if length(v_reason)<3 or length(v_reason)>1000 then raise exception 'decision reason required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_change from public.whatsapp_case_proposed_changes where id=p_change_id for update;
  if not found then raise exception 'proposed change not found'; end if;
  select * into v_case from public.whatsapp_communication_cases where id=v_change.case_id;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case proposal cannot be decided'; end if;
  if v_change.authority_status<>'REQUIRES_APPROVAL' then
    if exists(select 1 from public.whatsapp_case_events where case_id=v_change.case_id and correlation_key='proposal-decision:'||v_key) then
      return jsonb_build_object('case_id',v_change.case_id,'proposed_change_id',v_change.id,'authority_status',v_change.authority_status,'idempotent_replay',true);
    end if;
    raise exception 'proposed change already decided';
  end if;

  if v_decision='OPERATOR_APPROVED' and length(v_authority)<5 then
    raise exception 'operator approval requires documented standing authority reference';
  end if;
  if v_decision='CUSTOMER_APPROVED' then
    if p_source_message_id is null then raise exception 'customer approval requires inbound source message'; end if;
    select * into v_message from public.whatsapp_messages
    where id=p_source_message_id and packet_id=v_case.packet_id and direction='inbound'
      and created_at >= (v_change.created_at at time zone 'UTC');
    if not found then raise exception 'customer approval evidence must be a later inbound message from the same packet'; end if;
    select * into v_identity from public.whatsapp_case_identities
    where case_id=v_case.id and identity_role in ('ORIGINAL_COMMUNICATOR','SUBMITTING_SENDER') and resolution_status='CONFIRMED'
    order by case identity_role when 'ORIGINAL_COMMUNICATOR' then 0 else 1 end limit 1;
    if not found then raise exception 'customer approval requires a confirmed recipient/original communicator identity'; end if;

    select coalesce(max(version),0)+1 into v_version from public.whatsapp_case_confirmations where case_id=v_case.id;
    insert into public.whatsapp_case_confirmations(
      case_id,version,confirmation_scope,status,recipient_identity_id,source_message_id,confirmed_at,created_by
    ) values (
      v_case.id,v_version,jsonb_build_object('proposed_change_id',v_change.id,'change_type',v_change.change_type,
        'requested_value',v_change.requested_value,'proposed_value',v_change.proposed_value),
      'CONFIRMED',v_identity.id,v_message.id,statement_timestamp(),v_actor
    );
  end if;

  update public.whatsapp_case_proposed_changes
  set authority_status=v_decision,decided_by=v_actor,decided_at=statement_timestamp()
  where id=v_change.id returning * into v_change;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,resulting_state,metadata)
  values(v_case.id,'CASE_CHANGE_DECIDED',v_actor,'OPERATOR','proposal-decision:'||v_key,
    jsonb_build_object('proposed_change_id',v_change.id,'authority_status',v_change.authority_status),
    jsonb_build_object('reason',v_reason,'authority_reference',nullif(v_authority,''),'source_message_id',p_source_message_id));
  return jsonb_build_object('case_id',v_case.id,'proposed_change_id',v_change.id,'authority_status',v_change.authority_status,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_decide_case_proposed_change(uuid,text,uuid,text,text,text) from public,anon,authenticated;
grant execute on function public.whatsapp_decide_case_proposed_change(uuid,text,uuid,text,text,text) to authenticated;


create or replace function public.whatsapp_accept_case_handoff(
  p_case_id uuid,
  p_to_team text,
  p_reason text,
  p_open_work_snapshot jsonb,
  p_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_handoff public.whatsapp_case_handoffs%rowtype;
  v_team text:=upper(btrim(coalesce(p_to_team,'')));
  v_reason text:=btrim(coalesce(p_reason,''));
  v_key text:=btrim(coalesce(p_idempotency_key,''));
begin
  if v_actor is null or not public.has_whatsapp_permission('wa.intake.assign') then
    raise exception 'WhatsApp assignment permission required' using errcode='42501';
  end if;
  if not public.whatsapp_b2b_response_team_allowed(v_team) then raise exception 'unsupported WhatsApp handoff team'; end if;
  if length(v_reason)<5 or length(v_reason)>1000 then raise exception 'handoff reason required'; end if;
  if p_open_work_snapshot is null or jsonb_typeof(p_open_work_snapshot)<>'object' then raise exception 'open work snapshot required'; end if;
  if v_key='' or length(v_key)>160 then raise exception 'idempotency key required'; end if;

  select * into v_case from public.whatsapp_communication_cases where id=p_case_id for update;
  if not found then raise exception 'WhatsApp communication case not found'; end if;
  if v_case.status in ('CLOSED','CANCELLED') then raise exception 'closed case cannot be handed off'; end if;
  if v_case.accountable_owner_id is null or v_case.accountable_team is null then raise exception 'case must have an accountable owner before handoff'; end if;
  if v_case.accountable_owner_id=v_actor and v_case.accountable_team=v_team then raise exception 'handoff must change owner or team'; end if;

  select * into v_handoff from public.whatsapp_case_handoffs where case_id=p_case_id and correlation_key='handoff:'||v_key;
  if found then return jsonb_build_object('case_id',p_case_id,'handoff_id',v_handoff.id,'idempotent_replay',true); end if;

  insert into public.whatsapp_case_handoffs(
    case_id,from_team,from_owner_id,to_team,to_owner_id,reason,open_work_snapshot,accepted_by,accepted_at,correlation_key
  ) values (
    p_case_id,v_case.accountable_team,v_case.accountable_owner_id,v_team,v_actor,v_reason,p_open_work_snapshot,v_actor,statement_timestamp(),'handoff:'||v_key
  ) returning * into v_handoff;

  update public.whatsapp_communication_cases
  set accountable_team=v_team,accountable_owner_id=v_actor,accountability_status='ASSIGNED',assigned_at=statement_timestamp(),assigned_by=v_actor,updated_at=statement_timestamp()
  where id=p_case_id;

  insert into public.whatsapp_case_events(case_id,event_type,actor_id,actor_type,correlation_key,prior_state,resulting_state,metadata)
  values(p_case_id,'CASE_HANDOFF_ACCEPTED',v_actor,'OPERATOR','handoff-event:'||v_key,
    jsonb_build_object('team',v_handoff.from_team,'owner_id',v_handoff.from_owner_id),
    jsonb_build_object('team',v_handoff.to_team,'owner_id',v_handoff.to_owner_id),
    jsonb_build_object('handoff_id',v_handoff.id,'reason',v_reason,'open_work_snapshot',p_open_work_snapshot));
  return jsonb_build_object('case_id',p_case_id,'handoff_id',v_handoff.id,'accountable_team',v_team,'accountable_owner_id',v_actor,'idempotent_replay',false);
end;
$$;
revoke all on function public.whatsapp_accept_case_handoff(uuid,text,text,jsonb,text) from public,anon,authenticated;
grant execute on function public.whatsapp_accept_case_handoff(uuid,text,text,jsonb,text) to authenticated;


create or replace function public.whatsapp_get_case_commercial_layers(p_case_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path=pg_catalog,public,auth
as $$
declare
  v_actor uuid:=auth.uid();
  v_case public.whatsapp_communication_cases%rowtype;
  v_requested jsonb; v_interpretations jsonb; v_proposals jsonb; v_confirmations jsonb; v_handoffs jsonb; v_payment_proofs jsonb;
begin
  if v_actor is null or not public.is_whatsapp_inbox_reader(v_actor) then
    raise exception 'WhatsApp inbox read permission required' using errcode='42501';
  end if;
  select * into v_case from public.whatsapp_communication_cases where id=p_case_id;
  if not found then raise exception 'WhatsApp communication case not found'; end if;

  select coalesce(jsonb_agg(to_jsonb(x) order by x.line_number),'[]'::jsonb) into v_requested
  from (select id,line_number,source_message_ids,verbatim_request,product_text,quantity_text,unit_text,packaging_text,delivery_text,correction_of_line_id,superseded_at,created_at
        from public.whatsapp_case_requested_lines where case_id=p_case_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_interpretations
  from (select i.* from public.whatsapp_case_interpretations i join public.whatsapp_case_requested_lines r on r.id=i.requested_line_id where r.case_id=p_case_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_proposals
  from (select * from public.whatsapp_case_proposed_changes where case_id=p_case_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.version,x.id),'[]'::jsonb) into v_confirmations
  from (select * from public.whatsapp_case_confirmations where case_id=p_case_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.created_at,x.id),'[]'::jsonb) into v_handoffs
  from (select * from public.whatsapp_case_handoffs where case_id=p_case_id) x;
  select coalesce(jsonb_agg(to_jsonb(x) order by x.received_at,x.id),'[]'::jsonb) into v_payment_proofs
  from (select id,case_id,claimed_amount,claimed_reference,receipt_status,received_at,verified_amount,verified_reference,verified_by,verified_at,rejection_reason,correlation_key,created_at
        from public.whatsapp_case_payment_proofs where case_id=p_case_id) x;

  return jsonb_build_object('case_id',p_case_id,'requested_lines',v_requested,'interpretations',v_interpretations,
    'proposed_changes',v_proposals,'confirmations',v_confirmations,'handoffs',v_handoffs,'payment_proofs',v_payment_proofs);
end;
$$;
revoke all on function public.whatsapp_get_case_commercial_layers(uuid) from public,anon;
grant execute on function public.whatsapp_get_case_commercial_layers(uuid) to authenticated;
