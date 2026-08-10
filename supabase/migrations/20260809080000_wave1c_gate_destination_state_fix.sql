create or replace function public.company_destination_state_label_v1(p_company_id uuid) returns text language plpgsql stable security definer set search_path=public,pg_temp as $$
declare v_gst text; v_code text;
begin
 if p_company_id is null then return ''; end if;
 select lower(btrim(coalesce(gst_number,''))) into v_gst from public.companies where id=p_company_id;
 if v_gst<>'' then v_code:=left(regexp_replace(v_gst,'[[:space:]]','','g'),2); if v_code='07' then return 'delhi'; end if; end if;
 return '';
end $$;

create or replace function public.release_carton_at_dispatch_gate_v1(p_carton_id uuid,p_scan_evidence_id uuid) returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare v_carton public.dispatch_cartons%rowtype; v_order public.orders%rowtype; v_scan public.operational_scan_records%rowtype; v_blockers jsonb:='[]'; v_threshold numeric; v_remaining int;
begin
 perform public.assert_order_transition_role('gate_release');
 select * into v_carton from public.dispatch_cartons where id=p_carton_id for update;
 if not found then return jsonb_build_object('ok',false,'blockers',jsonb_build_array(jsonb_build_object('code','carton_not_found'))); end if;
 if v_carton.status='physically_dispatched' then return jsonb_build_object('ok',true,'carton_id',p_carton_id,'already_released',true); end if;
 select * into v_scan from public.operational_scan_records where id=p_scan_evidence_id;
 if not found or v_scan.entity_id is distinct from p_carton_id or v_scan.order_id is distinct from v_carton.order_id
    or coalesce(v_scan.entity_type,'')<>'dispatch_carton' or coalesce(v_scan.scan_type,'') not in('carton','dispatch_gate')
    or coalesce(v_scan.verification_status,'') not in('scanned','verified') or nullif(btrim(coalesce(v_carton.barcode_string,'')),'') is null
    or lower(btrim(coalesce(v_scan.barcode_value,''))) is distinct from lower(btrim(coalesce(v_carton.barcode_string,''))) then
   v_blockers:=jsonb_build_array(jsonb_build_object('code','invalid_scan_evidence'));
 end if;
 select * into v_order from public.orders where id=v_carton.order_id for update;
 if not found or v_order.status<>'cleared_for_dispatch' then v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','order_not_cleared')); end if;
 if not coalesce(v_order.payment_cleared,false) or public.order_collectible_balance_v1(v_order.id)>0.01 then v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','finance_not_cleared')); end if;
 if nullif(btrim(v_order.final_invoice_url),'') is null then v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','invoice_missing')); end if;
 -- No governed consignor-state field exists yet, so intra-state movement cannot
 -- be proven. Fail closed at the conservative threshold for every destination.
 v_threshold:=50000;
 if coalesce(v_order.sales_order_value,0)>v_threshold and nullif(btrim(v_order.eway_bill_number),'') is null then v_blockers:=v_blockers||jsonb_build_array(jsonb_build_object('code','eway_missing')); end if;
 if jsonb_array_length(v_blockers)>0 then insert into public.dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,blockers,actor_id,actor_role) values(p_carton_id,v_carton.order_id,p_scan_evidence_id,'denied',v_blockers,auth.uid(),public.get_user_role(auth.uid())); return jsonb_build_object('ok',false,'blockers',v_blockers); end if;
 update public.dispatch_cartons set status='physically_dispatched',scanned_out_at=now() where id=p_carton_id;
 insert into public.dispatch_gate_decisions(carton_id,order_id,scan_evidence_id,decision,actor_id,actor_role) values(p_carton_id,v_order.id,p_scan_evidence_id,'released',auth.uid(),public.get_user_role(auth.uid()));
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value) values('CARTON_GATE_RELEASED','SecurityGate','dispatch_cartons',p_carton_id::text,auth.uid(),'high',jsonb_build_object('order_id',v_order.id,'scan_evidence_id',p_scan_evidence_id));
 select count(*) into v_remaining from public.dispatch_cartons where order_id=v_order.id and status is distinct from 'physically_dispatched';
 return jsonb_build_object('ok',true,'carton_id',p_carton_id,'order_id',v_order.id,'remaining_cartons',v_remaining,'already_released',false);
end $$;
revoke all on function public.company_destination_state_label_v1(uuid) from public,anon;
revoke all on function public.release_carton_at_dispatch_gate_v1(uuid,uuid) from public,anon;
grant execute on function public.release_carton_at_dispatch_gate_v1(uuid,uuid) to authenticated,service_role;
