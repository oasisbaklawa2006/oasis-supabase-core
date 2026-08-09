-- Replacement is in a dedicated migration so clean replay includes both ambiguity fixes.
-- The prior six-argument overload is replaced in-place; no public overload is retained.
drop function if exists public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb);
create function public.approve_sales_order_draft_for_so_atomic(p_draft_id uuid,p_expected_extraction_request_key text,p_actor_id uuid,p_actor_name text,p_review_notes text default null,p_metadata jsonb default '{}')
returns table(draft_id uuid,promoted_order_id uuid,order_number text,already_promoted boolean) language plpgsql security definer set search_path=public,pg_temp as $$
#variable_conflict use_column
declare v_draft public.sales_order_drafts%rowtype; v_order_id uuid; v_order_number text; v_line record; v_qty numeric; v_lines int:=0;
begin
 if auth.uid() is null or not public.is_whatsapp_inbox_reader(auth.uid()) or p_actor_id is distinct from auth.uid() then raise exception 'NOT_AUTHORIZED' using errcode='P0001'; end if;
 select * into v_draft from public.sales_order_drafts d where d.id=p_draft_id for update;
 if not found then raise exception 'DRAFT_NOT_FOUND'; end if;
 if v_draft.extraction_request_key is distinct from btrim(p_expected_extraction_request_key) then raise exception 'IDEMPOTENCY_KEY_MISMATCH'; end if;
 if v_draft.promoted_order_id is not null then select o.order_number into v_order_number from public.orders o where o.id=v_draft.promoted_order_id; return query select p_draft_id,v_draft.promoted_order_id,v_order_number,true; return; end if;
 if v_draft.status<>'UNDER_REVIEW' or v_draft.company_id is null then raise exception 'DRAFT_NOT_READY'; end if;
 perform public.validate_sales_order_draft_readiness(v_draft.readiness_dimensions);
 select count(*) into v_lines from public.sales_order_draft_lines l where l.draft_id=p_draft_id and l.product_id is not null and coalesce(l.operator_quantity,l.normalized_quantity,l.raw_quantity,0)>0;
 if v_lines=0 then raise exception 'DRAFT_HAS_NO_VALID_LINES'; end if;
 perform set_config('app.order_authority_managed','on',true);
 insert into public.orders(company_id,status,order_origin,payment_status,tracking_token) values(v_draft.company_id,'submitted','LEGACY_ERP','awaiting_receipt',encode(extensions.gen_random_bytes(16),'hex')) returning id,public.orders.order_number into v_order_id,v_order_number;
 for v_line in select l.* from public.sales_order_draft_lines l where l.draft_id=p_draft_id order by l.line_index loop
   v_qty:=coalesce(v_line.operator_quantity,v_line.normalized_quantity,v_line.raw_quantity,0); if v_line.product_id is not null and v_qty>0 then insert into public.order_items(order_id,product_id,quantity,pack_size,notes) values(v_order_id,v_line.product_id,v_qty,coalesce(v_line.normalized_unit,v_line.raw_unit),left(coalesce(v_line.product_name,''),500)); end if;
 end loop;
 perform public.restore_order_financials(v_order_id);
 update public.sales_order_drafts d set status='APPROVED_FOR_SO',promoted_order_id=v_order_id,approver_id=p_actor_id,approver_name=p_actor_name,review_notes=p_review_notes,updated_by=p_actor_id where d.id=p_draft_id;
 insert into public.sales_order_draft_audit_log(draft_id,action,from_status,to_status,actor_id,actor_name,metadata) values(p_draft_id,'APPROVE','UNDER_REVIEW','APPROVED_FOR_SO',p_actor_id,p_actor_name,coalesce(p_metadata,'{}')||jsonb_build_object('promoted_order_id',v_order_id));
 insert into public.audit_logs(action_type,module_name,entity_name,entity_id,actor_id,risk_level,new_value) values('WA_DRAFT_PROMOTED_TO_SO','WhatsApp','orders',v_order_id::text,p_actor_id,'high',jsonb_build_object('draft_id',p_draft_id));
 return query select p_draft_id,v_order_id,v_order_number,false;
end $$;
revoke all on function public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb) from public,anon;
grant execute on function public.approve_sales_order_draft_for_so_atomic(uuid,text,uuid,text,text,jsonb) to authenticated,service_role;
