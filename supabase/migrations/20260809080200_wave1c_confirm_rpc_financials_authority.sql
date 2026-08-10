create or replace function public.confirm_prepaid_order_awaiting_advance_v1(p_order_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_order public.orders%rowtype; v_total numeric; v_advance numeric;
begin
 perform public.assert_order_transition_role('confirm_awaiting_advance'); select * into v_order from public.orders where id=p_order_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','not_found'))); end if;
 if v_order.status='awaiting_advance' then return jsonb_build_object('ok',true,'order_id',p_order_id,'already_applied',true); end if;
 if v_order.status<>'submitted' then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','invalid_status'))); end if;
 perform 1 from public.order_items where order_id=p_order_id for update;
 v_total:=public.restore_order_financials(p_order_id);
 select advance_required into v_advance from public.orders where id=p_order_id;
 if coalesce(v_total,0)<=0 or coalesce(v_advance,0)<=0 then raise exception 'AUTHORITATIVE_FINANCIALS_NOT_DERIVED' using errcode='P0001'; end if;
 update public.orders set status='awaiting_advance',payment_status='awaiting_receipt',payment_rejection_reason=null where id=p_order_id;
 insert into public.order_status_history(order_id,old_status,new_status,changed_by) values(p_order_id,v_order.status,'awaiting_advance',auth.uid());
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value) values('ORDER_CONFIRMED_AWAITING_ADVANCE','Sales','orders',p_order_id::text,auth.uid(),'high',jsonb_build_object('sales_order_value',v_total,'advance_required',v_advance));
 return jsonb_build_object('ok',true,'order_id',p_order_id,'status','awaiting_advance','advance_required',v_advance,'already_applied',false);
end $$;
drop function if exists public.release_order_to_manufacturing_v1(uuid,text,numeric,numeric);
revoke all on function public.confirm_prepaid_order_awaiting_advance_v1(uuid) from public,anon;
grant execute on function public.confirm_prepaid_order_awaiting_advance_v1(uuid) to authenticated,service_role;
