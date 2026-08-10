-- Wave 1C: close REST bypasses and expose governed lifecycle RPCs only.
create table if not exists public.dispatch_gate_decisions(
 id uuid primary key default gen_random_uuid(), carton_id uuid not null references public.dispatch_cartons(id),
 order_id uuid references public.orders(id), scan_evidence_id uuid not null references public.operational_scan_records(id),
 decision text not null check(decision in ('released','denied')), blockers jsonb not null default '[]',
 actor_id uuid not null, actor_role text, metadata jsonb not null default '{}', created_at timestamptz not null default now()
);
alter table public.dispatch_gate_decisions enable row level security;
drop policy if exists dispatch_gate_decisions_staff_select on public.dispatch_gate_decisions;
create policy dispatch_gate_decisions_staff_select on public.dispatch_gate_decisions for select to authenticated using(public.is_internal_staff(auth.uid()));
revoke insert,update,delete on public.dispatch_gate_decisions from public,anon,authenticated;
grant select on public.dispatch_gate_decisions to authenticated,service_role;

create or replace function public.prevent_dispatch_gate_decision_mutation() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'dispatch_gate_decisions are append-only' using errcode='P0001'; end $$;
drop trigger if exists trg_dispatch_gate_decisions_no_update on public.dispatch_gate_decisions;
create trigger trg_dispatch_gate_decisions_no_update before update or delete on public.dispatch_gate_decisions for each row execute function public.prevent_dispatch_gate_decision_mutation();

create or replace function public.protect_dispatch_carton_authority_fields() returns trigger language plpgsql set search_path=public,pg_temp as $$
begin
 if current_user='postgres' then return new; end if;
 if new.status is distinct from old.status or new.scanned_out_at is distinct from old.scanned_out_at then
   raise exception 'CARTON_RELEASE_AUTHORITY_REQUIRED' using errcode='P0001';
 end if; return new;
end $$;
drop trigger if exists trg_protect_dispatch_carton_authority_fields on public.dispatch_cartons;
create trigger trg_protect_dispatch_carton_authority_fields before update on public.dispatch_cartons for each row execute function public.protect_dispatch_carton_authority_fields();

create or replace function public.order_collectible_balance_v1(p_order_id uuid) returns numeric language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_total numeric; v_advance numeric; v_verified numeric;
begin
 select sales_order_value,advance_paid into v_total,v_advance from public.orders where id=p_order_id;
 if not found then return null; end if;
 select coalesce(sum(amount),0) into v_verified from public.order_payments
 where order_id=p_order_id
   and lower(btrim(coalesce(status,'')))='verified'
   and lower(btrim(coalesce(payment_type,'')))<>'advance';
 return greatest(0,coalesce(v_total,0)-coalesce(v_advance,0)-v_verified);
end $$;

create or replace function public.update_order_finance_verification_v1(p_order_id uuid,p_payment_status text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_order public.orders%rowtype; v_payment text:=lower(btrim(coalesce(p_payment_status,'')));
begin
 perform public.assert_order_transition_role('finance_review');
 if not public.is_advance_verification_path_cleared(v_payment) then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_payment_status'))); end if;
 select * into v_order from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if lower(coalesce(v_order.status,'')) not in ('submitted','awaiting_advance','awaiting_payment','awaiting_final_payment','confirmed') then
   return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status')));
 end if;
 update public.orders set payment_status=v_payment,finance_verified_by=auth.uid(),finance_verified_at=now(),payment_rejection_reason=null where id=p_order_id;
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value) values('ORDER_FINANCE_VERIFIED','Finance','orders',p_order_id::text,auth.uid(),'high',jsonb_build_object('payment_status',v_payment));
 return jsonb_build_object('ok',true,'order_id',p_order_id,'payment_status',v_payment);
end $$;

create or replace function public.reject_order_finance_review_v1(p_order_id uuid,p_rejection_reason text) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_reason text:=btrim(coalesce(p_rejection_reason,'')); v_order public.orders%rowtype;
begin
 perform public.assert_order_transition_role('finance_review'); if v_reason='' then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','reason_required'))); end if;
 select * into v_order from public.orders where id=p_order_id for update; if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if lower(coalesce(v_order.status,'')) not in ('submitted','awaiting_advance','awaiting_payment','awaiting_final_payment','confirmed') then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status'))); end if;
 update public.orders set payment_status='awaiting_receipt',payment_rejection_reason=v_reason,finance_verified_by=null,finance_verified_at=null where id=p_order_id;
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,reason) values('ORDER_FINANCE_REJECTED','Finance','orders',p_order_id::text,auth.uid(),'high',v_reason);
 return jsonb_build_object('ok',true,'order_id',p_order_id,'payment_status','awaiting_receipt');
end $$;

create or replace function public.record_order_fully_paid_v1(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_order public.orders%rowtype; v_balance numeric;
begin
 perform public.assert_order_transition_role('record_full_payment'); select * into v_order from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 v_balance:=public.order_collectible_balance_v1(p_order_id);
 if coalesce(v_order.payment_cleared,false) and lower(btrim(coalesce(v_order.payment_status,'')))='paid' and v_balance<=0.01 then
   return jsonb_build_object('ok',true,'order_id',p_order_id,'payment_status','paid','already_applied',true);
 end if;
 if v_balance>0.01 then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','balance_outstanding','amount',v_balance))); end if;
 update public.orders set payment_status='paid',payment_cleared=true,finance_verified_by=auth.uid(),finance_verified_at=now() where id=p_order_id;
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value) values('ORDER_RECORDED_FULLY_PAID','Finance','orders',p_order_id::text,auth.uid(),'high',jsonb_build_object('collectible_balance',v_balance));
 return jsonb_build_object('ok',true,'order_id',p_order_id,'payment_status','paid','already_applied',false);
end $$;

do $$ declare r record; begin
 for r in select p.oid,p.proname,pg_get_function_identity_arguments(p.oid) args from pg_proc p join pg_namespace n on n.oid=p.pronamespace where n.nspname='public' and p.proname in ('record_order_fully_paid_v1','update_order_finance_verification_v1','reject_order_finance_review_v1','order_collectible_balance_v1') loop
   execute format('revoke all on function public.%I(%s) from public,anon',r.proname,r.args);
 end loop; end $$;
grant execute on function public.record_order_fully_paid_v1(uuid) to authenticated,service_role;
grant execute on function public.update_order_finance_verification_v1(uuid,text) to authenticated,service_role;
grant execute on function public.reject_order_finance_review_v1(uuid,text) to authenticated,service_role;
grant execute on function public.order_collectible_balance_v1(uuid) to authenticated,service_role;

create or replace function public.release_order_to_manufacturing_v1(p_order_id uuid,p_payment_status text default null) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.orders%rowtype; v_payment text;
begin
 perform public.assert_order_transition_role('release_manufacturing'); select * into v from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if v.status in('manufacturing','in_production','packed_ready','cleared_for_dispatch','dispatched','delivered') then return jsonb_build_object('ok',true,'order_id',p_order_id,'new_status',v.status,'already_applied',true); end if;
 v_payment:=lower(btrim(coalesce(v.payment_status,'')));
 if p_payment_status is not null and lower(btrim(p_payment_status)) is distinct from v_payment then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','payment_status_mismatch'))); end if;
 if v.status not in('awaiting_advance','confirmed','submitted','awaiting_payment','awaiting_final_payment') or not public.is_advance_verification_path_cleared(v_payment) or coalesce(v.advance_paid,0)<coalesce(v.advance_required,0) or v.finance_verified_by is null or v.finance_verified_at is null then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','finance_not_cleared'))); end if;
 update public.orders set status='manufacturing' where id=p_order_id;
 insert into public.order_status_history(order_id,old_status,new_status,changed_by) values(p_order_id,v.status,'manufacturing',auth.uid());
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level) values('ORDER_RELEASED_TO_MANUFACTURING','Finance','orders',p_order_id::text,auth.uid(),'high');
 return jsonb_build_object('ok',true,'order_id',p_order_id,'new_status','manufacturing','already_applied',false);
end $$;

create or replace function public.release_order_to_in_production_v1(p_order_id uuid,p_payment_status text default null) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.orders%rowtype; v_payment text;
begin
 perform public.assert_order_transition_role('release_manufacturing'); select * into v from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if v.status in('in_production','packed_ready','cleared_for_dispatch','dispatched','delivered') then return jsonb_build_object('ok',true,'order_id',p_order_id,'new_status',v.status,'already_applied',true); end if;
 v_payment:=lower(btrim(coalesce(v.payment_status,'')));
 if p_payment_status is not null and lower(btrim(p_payment_status)) is distinct from v_payment then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','payment_status_mismatch'))); end if;
 if v.status not in('manufacturing','awaiting_advance','confirmed','submitted','awaiting_payment') or not public.is_advance_verification_path_cleared(v_payment) or coalesce(v.advance_paid,0)<coalesce(v.advance_required,0) or v.finance_verified_by is null or v.finance_verified_at is null then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','finance_not_cleared'))); end if;
 update public.orders set status='in_production' where id=p_order_id;
 insert into public.order_status_history(order_id,old_status,new_status,changed_by) values(p_order_id,v.status,'in_production',auth.uid());
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level) values('ORDER_RELEASED_TO_PRODUCTION','Finance','orders',p_order_id::text,auth.uid(),'high');
 return jsonb_build_object('ok',true,'order_id',p_order_id,'new_status','in_production','already_applied',false);
end $$;

create or replace function public.release_order_to_packed_ready_v1(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.orders%rowtype; v_open int;
begin
 perform public.assert_order_transition_role('mark_packed_ready'); select * into v from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if v.status='packed_ready' then return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',true); end if;
 if v.status not in('in_production','manufacturing','assembled','packing','partial_ready') then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status'))); end if;
 select count(*) into v_open from public.order_items where order_id=p_order_id and (lower(coalesce(production_status,'')) not in('completed','partial_ready') or coalesce(actual_packed_qty,0)<coalesce(quantity,0));
 if v_open>0 then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','packing_incomplete','lines',v_open))); end if;
 update public.orders set status='packed_ready' where id=p_order_id;
 insert into public.order_status_history(order_id,old_status,new_status,changed_by) values(p_order_id,v.status,'packed_ready',auth.uid());
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level) values('ORDER_MARKED_PACKED_READY','Operations','orders',p_order_id::text,auth.uid(),'high');
 return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',false);
end $$;

create or replace function public.clear_order_for_dispatch_v1(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v public.orders%rowtype; v_balance numeric;
begin
 perform public.assert_order_transition_role('clear_dispatch'); select * into v from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if v.status='cleared_for_dispatch' then return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',true); end if;
 v_balance:=public.order_collectible_balance_v1(p_order_id);
 if v.status not in('packed_ready','awaiting_final_payment') or not coalesce(v.payment_cleared,false) or v_balance>0.01 or nullif(btrim(v.final_invoice_url),'') is null then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','dispatch_prerequisites_failed','collectible_balance',v_balance))); end if;
 update public.orders set status='cleared_for_dispatch' where id=p_order_id;
 insert into public.order_status_history(order_id,old_status,new_status,changed_by) values(p_order_id,v.status,'cleared_for_dispatch',auth.uid());
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level) values('ORDER_CLEARED_FOR_DISPATCH','Dispatch','orders',p_order_id::text,auth.uid(),'high');
 return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',false);
end $$;

revoke all on function public.release_order_to_manufacturing_v1(uuid,text) from public,anon;
revoke all on function public.release_order_to_in_production_v1(uuid,text) from public,anon;
revoke all on function public.release_order_to_packed_ready_v1(uuid) from public,anon;
revoke all on function public.clear_order_for_dispatch_v1(uuid) from public,anon;
grant execute on function public.release_order_to_manufacturing_v1(uuid,text) to authenticated,service_role;
grant execute on function public.release_order_to_in_production_v1(uuid,text) to authenticated,service_role;
grant execute on function public.release_order_to_packed_ready_v1(uuid) to authenticated,service_role;
grant execute on function public.clear_order_for_dispatch_v1(uuid) to authenticated,service_role;

-- Serialize governed pricing proposals across all submitters. RLS intentionally
-- exposes only a user's own drafts, so client-side duplicate checks cannot
-- provide cross-user idempotency.
create or replace function public.submit_catalogue_pricing_draft_v1(
  p_operation text,
  p_target_record_id uuid,
  p_payload jsonb
) returns table(draft_id uuid, already_pending boolean)
language plpgsql security definer set search_path=public,pg_temp as $$
declare v_user uuid:=auth.uid(); v_product text:=nullif(btrim(p_payload->>'product_id'),''); v_channel text:=nullif(btrim(p_payload->>'price_channel'),''); v_id uuid;
begin
  if v_user is null then raise exception 'NOT_AUTHENTICATED' using errcode='P0001'; end if;
  if not public.has_catalogue_permission('catalogue.pricing.submit') then raise exception 'NOT_AUTHORIZED' using errcode='P0001'; end if;
  if p_operation not in ('create','update') or v_product is null or v_channel is null then raise exception 'INVALID_PRICING_DRAFT' using errcode='P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(v_product||':'||lower(v_channel),0));
  select d.id into v_id from public.catalogue_pricing_drafts d
   where d.status='pending_approval' and d.payload->>'product_id'=v_product and lower(d.payload->>'price_channel')=lower(v_channel)
   order by d.created_at,d.id limit 1;
  if v_id is not null then return query select v_id,true; return; end if;
  insert into public.catalogue_pricing_drafts(source_app,target_table,target_record_id,operation,payload,status,submitted_by,submitted_at,created_at,updated_at)
  values('catalogue_app','pricing_slabs',p_target_record_id,p_operation,p_payload,'pending_approval',v_user,now(),now(),now()) returning id into v_id;
  return query select v_id,false;
end $$;
revoke all on function public.submit_catalogue_pricing_draft_v1(text,uuid,jsonb) from public,anon;
grant execute on function public.submit_catalogue_pricing_draft_v1(text,uuid,jsonb) to authenticated,service_role;
