-- Governed WA provider callback reconciliation, 2026-10-26.
-- Forward-only additive terminal FAILED_FINAL support. No existing row updates.
-- destructive-change-approved: replace narrow provider-ID status CHECK with one that also permits terminal FAILED_FINAL.
-- rollback-plan: do not automatically roll back after terminal callbacks are written; use a separately reviewed compensating migration after evidencing no FAILED_FINAL/provider-ID rows.
begin;
alter table public.whatsapp_operator_reply_outbox
 drop constraint if exists whatsapp_operator_reply_outbox_provider_message_id_check;
alter table public.whatsapp_operator_reply_outbox
 add constraint whatsapp_operator_reply_outbox_provider_message_id_check
 check (provider_message_id is null or status in ('ACCEPTED','DELIVERED','READ','FAILED_FINAL'));

create or replace function public.persist_whatsapp_operator_reply_provider_status(
 p_provider_message_id text, p_status text, p_evidence jsonb default '{}'::jsonb
) returns jsonb language plpgsql security definer
 set search_path = pg_catalog, public, auth, pg_temp as $$
declare
 v_reply public.whatsapp_operator_reply_outbox%rowtype;
 v_target text := upper(btrim(coalesce(p_status,'')));
 v_now timestamptz := clock_timestamp();
 v_current_rank integer;
 v_target_rank integer;
 v_error_code text := left(regexp_replace(coalesce(p_evidence->>'provider_error_code',''),'[^A-Za-z0-9_.:-]','','g'),64);
begin
 if auth.uid() is not null or coalesce(auth.jwt()->>'role','') <> 'service_role' then
   raise exception 'WA5_SERVICE_ROLE_REQUIRED' using errcode='P0001';
 end if;
 if nullif(btrim(coalesce(p_provider_message_id,'')),'') is null then
   raise exception 'WA_STATUS_PROVIDER_ID_MISSING' using errcode='P0001';
 end if;
 if v_target not in ('ACCEPTED','DELIVERED','READ','FAILED_FINAL') then
   raise exception 'WA5_INVALID_PROVIDER_STATUS' using errcode='P0001';
 end if;
 select * into v_reply from public.whatsapp_operator_reply_outbox
 where provider_message_id = btrim(p_provider_message_id)
 order by created_at,id limit 1 for update;
 if not found then
   return jsonb_build_object('matched',false,'updated',false,'status',null);
 end if;
 if exists(select 1 from public.whatsapp_operator_reply_outbox
           where provider_message_id=btrim(p_provider_message_id) and id<>v_reply.id) then
   raise exception 'WA_STATUS_PROVIDER_MESSAGE_AMBIGUOUS' using errcode='P0001';
 end if;
 v_current_rank:=case upper(v_reply.status)
   when 'QUEUED' then 0 when 'SENDING' then 1 when 'ACCEPTANCE_UNKNOWN' then 1
   when 'ACCEPTED' then 2 when 'DELIVERED' then 3 when 'READ' then 4 else -1 end;
 v_target_rank:=case v_target
   when 'ACCEPTED' then 2 when 'DELIVERED' then 3 when 'READ' then 4 else -1 end;
 if v_reply.status = 'FAILED_FINAL'
    or (v_target='FAILED_FINAL' and upper(v_reply.status) in ('DELIVERED','READ'))
    or (v_target<>'FAILED_FINAL' and v_target_rank<=v_current_rank) then
   return jsonb_build_object('matched',true,'updated',false,'status',upper(v_reply.status));
 end if;
 if v_current_rank<0 then
   raise exception 'WA_STATUS_BOUNDARY_OR_REGRESSION' using errcode='P0001';
 end if;
 update public.whatsapp_operator_reply_outbox
 set status = v_target,
     accepted_at = case when v_target='FAILED_FINAL' then accepted_at else coalesce(accepted_at,v_now) end,
     delivered_at = case when v_target in ('DELIVERED','READ') then coalesce(delivered_at,v_now) else delivered_at end,
     read_at = case when v_target='READ' then coalesce(read_at,v_now) else read_at end,
     lease_token = null,
     lease_expires_at = null,
     last_error_code = case when v_target='FAILED_FINAL' then coalesce(nullif(v_error_code,''),'PROVIDER_FAILED') else null end,
     last_error_detail = case when v_target='FAILED_FINAL' then 'Provider reported terminal delivery failure' else null end,
     updated_at = v_now
 where id=v_reply.id;
 insert into public.whatsapp_operator_reply_events(reply_id,event_type,actor_id,evidence)
 values (v_reply.id,'PROVIDER_STATUS_CALLBACK',null,
   jsonb_build_object('provider_status',lower(btrim(p_status)),'target_status',v_target,
       'provider_message_id_present',true)
     || case when v_target='FAILED_FINAL' then jsonb_build_object('provider_error_code',coalesce(nullif(v_error_code,''),'PROVIDER_FAILED')) else '{}'::jsonb end
 );
 return jsonb_build_object('matched',true,'updated',true,'status',v_target);
end;
$$;
revoke all on function public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb) from public,anon,authenticated;
grant execute on function public.persist_whatsapp_operator_reply_provider_status(text,text,jsonb) to service_role;
commit;
