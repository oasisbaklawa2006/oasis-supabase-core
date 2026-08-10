-- Trace Gate 3: canonical role authority, atomic/idempotent chain mutations.
-- Schema/RLS/RPC ownership is intentionally in Core, never oasis-trace.

do $$
declare n text;
begin
  foreach n in array array[
    'ols_production_batches','ols_production_labels','ols_stock_units','ols_inventory_movements',
    'ols_cartons','ols_dpl_documents','ols_dpl_cartons','ols_finance_pi','ols_finance_pi_cartons',
    'ols_finance_pi_lines','ols_shipping_labels','ols_print_logs','ols_audit_logs'
  ] loop
    if to_regclass('public.' || n) is null then
      raise exception 'TRACE_SCHEMA_PREREQUISITE_MISSING: %', n using errcode='P0001';
    end if;
  end loop;
end $$;

create table if not exists public.ols_trace_mutation_receipts (
  id uuid primary key default gen_random_uuid(),
  idempotency_key text not null unique,
  operation text not null,
  payload_fingerprint text not null,
  response jsonb not null,
  actor_id uuid not null,
  created_at timestamptz not null default now()
);

alter table public.ols_audit_logs add column if not exists idempotency_key text;
create unique index if not exists ols_audit_logs_idempotency_key_uniq
  on public.ols_audit_logs(idempotency_key) where idempotency_key is not null;
create unique index if not exists ols_dpl_cartons_dpl_carton_uniq on public.ols_dpl_cartons(dpl_id,carton_id);
create unique index if not exists ols_dpl_cartons_single_membership_uniq on public.ols_dpl_cartons(carton_id);
create unique index if not exists ols_finance_pi_cartons_pi_carton_uniq on public.ols_finance_pi_cartons(pi_id,carton_id);
create unique index if not exists ols_finance_pi_cartons_single_membership_uniq on public.ols_finance_pi_cartons(carton_id);
create unique index if not exists ols_shipping_labels_carton_uniq on public.ols_shipping_labels(carton_id);

create or replace function public.trace_role_allowed_v1(p_action text)
returns boolean language sql stable security invoker set search_path=public,pg_temp as $$
  with roles as (select upper(x) role from unnest(public.get_current_user_roles()) x)
  select auth.uid() is not null and case p_action
    when 'production' then exists(select 1 from roles where role in ('PRODUCTION','PRODUCTION_HEAD','PRODUCTION_MANAGER','OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'))
    when 'packing' then exists(select 1 from roles where role in ('PACKING','PACKING_SUPERVISOR','ASSEMBLY_SUPERVISOR','ASSEMBLY_HEAD','OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'))
    when 'dispatch' then exists(select 1 from roles where role in ('DISPATCH','DISPATCH_HEAD','DISPATCH_MANAGER','DISPATCH_INCHARGE','OPERATIONS_MANAGER','ADMIN','SUPER_ADMIN','OWNER'))
    when 'finance' then exists(select 1 from roles where role in ('FINANCE','FINANCE_HEAD','FINANCE_EXEC','ADMIN','SUPER_ADMIN','OWNER'))
    else false end
$$;

create or replace function public.trace_assert_role_v1(p_action text)
returns void language plpgsql stable security invoker set search_path=public,pg_temp as $$
begin
  if auth.uid() is null then raise exception 'NOT_AUTHENTICATED' using errcode='P0001'; end if;
  if not public.trace_role_allowed_v1(p_action) then
    raise exception 'NOT_AUTHORIZED: Trace % authority required',p_action using errcode='P0001';
  end if;
end $$;

create or replace function public.trace_audit_immutable_v1()
returns trigger language plpgsql set search_path=public,pg_temp as $$
begin raise exception 'TRACE_AUDIT_IMMUTABLE: % rejected',tg_op using errcode='P0001'; end $$;
drop trigger if exists trg_ols_audit_logs_immutable on public.ols_audit_logs;
create trigger trg_ols_audit_logs_immutable before update or delete on public.ols_audit_logs
for each row execute function public.trace_audit_immutable_v1();
drop trigger if exists trg_ols_trace_receipts_immutable on public.ols_trace_mutation_receipts;
create trigger trg_ols_trace_receipts_immutable before update or delete on public.ols_trace_mutation_receipts
for each row execute function public.trace_audit_immutable_v1();

create or replace function public.trace_create_production_v1(p_input jsonb,p_labels jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare f text:=md5(p_input::text||p_labels::text); prior record; b public.ols_production_batches; l public.ols_production_labels; item jsonb; out_labels jsonb:='[]'; result jsonb;
begin
  perform public.trace_assert_role_v1('production');
  if nullif(btrim(p_idempotency_key),'') is null or jsonb_typeof(p_labels)<>'array' or jsonb_array_length(p_labels)<1 then raise exception 'INVALID_TRACE_MUTATION' using errcode='P0001'; end if;
  perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  select payload_fingerprint,response into prior from public.ols_trace_mutation_receipts where idempotency_key=p_idempotency_key;
  if found then if prior.payload_fingerprint<>f then raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode='P0001'; end if; return prior.response; end if;
  insert into public.ols_production_batches(batch_no,product_id,department_id,shift,mfg_date,shelf_life_days,qc_status,remarks,created_by)
  values(p_input->>'batch_no',(p_input->>'product_id')::uuid,(p_input->>'department_id')::uuid,p_input->>'shift',(p_input->>'mfg_date')::date,(p_input->>'shelf_life_days')::int,p_input->>'qc_status',p_input->>'remarks',auth.uid()) returning * into b;
  for item in select value from jsonb_array_elements(p_labels) loop
    insert into public.ols_production_labels(label_no,batch_id,product_id,department_id,tray_serial,net_weight,gross_weight,mfg_date,best_before,qc_status,operator_name,status,metadata,created_by)
    values(item->>'label_no',b.id,(item->>'product_id')::uuid,(item->>'department_id')::uuid,item->>'tray_serial',(item->>'net_weight')::numeric,(item->>'gross_weight')::numeric,(item->>'mfg_date')::date,(item->>'best_before')::date,item->>'qc_status',item->>'operator_name','active',coalesce(item->'metadata','{}'),auth.uid()) returning * into l;
    insert into public.ols_stock_units(production_label_id,current_location,current_status) values(l.id,'store','in_stock');
    insert into public.ols_inventory_movements(production_label_id,from_location,to_location,movement_type,reference_no,user_id) values(l.id,'production','store','production_inward',b.batch_no,auth.uid());
    out_labels:=out_labels||to_jsonb(l);
  end loop;
  result:=jsonb_build_object('batch',to_jsonb(b),'labels',out_labels);
  insert into public.ols_audit_logs(action,entity_type,entity_id,user_id,details,idempotency_key) values('trace_production_created','production_batch',b.id,auth.uid(),jsonb_build_object('label_count',jsonb_array_length(p_labels)),p_idempotency_key);
  insert into public.ols_trace_mutation_receipts(idempotency_key,operation,payload_fingerprint,response,actor_id) values(p_idempotency_key,'create_production',f,result,auth.uid()); return result;
end $$;

create or replace function public.trace_finalize_carton_v1(p_carton_id uuid,p_net_weight numeric,p_gross_weight numeric,p_copied_to_clipboard boolean,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare f text:=md5(concat_ws('|',p_carton_id,p_net_weight,p_gross_weight,p_copied_to_clipboard)); prior record; c public.ols_cartons; result jsonb;
begin
  perform public.trace_assert_role_v1('packing'); perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  select payload_fingerprint,response into prior from public.ols_trace_mutation_receipts where idempotency_key=p_idempotency_key;
  if found then if prior.payload_fingerprint<>f then raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode='P0001'; end if; return prior.response; end if;
  select * into c from public.ols_cartons where id=p_carton_id for update;
  if not found or c.status<>'draft' or not exists(select 1 from public.ols_carton_contents where carton_id=c.id) then raise exception 'CARTON_NOT_FINALIZABLE' using errcode='P0001'; end if;
  update public.ols_cartons set status='packed',packed_at=now(),packed_by=auth.uid(),net_weight=p_net_weight,gross_weight=p_gross_weight where id=c.id returning * into c;
  insert into public.ols_print_logs(ref_type,ref_id,printed_by,success,is_reprint,reprint_count,reason) values('carton',c.id,auth.uid(),true,false,0,case when p_copied_to_clipboard then 'command_generated_clipboard_copied' else 'command_generated_clipboard_unavailable' end);
  result:=to_jsonb(c); insert into public.ols_audit_logs(action,entity_type,entity_id,user_id,details,idempotency_key) values('trace_carton_finalized','carton',c.id,auth.uid(),'{}',p_idempotency_key);
  insert into public.ols_trace_mutation_receipts values(default,p_idempotency_key,'finalize_carton',f,result,auth.uid(),default); return result;
end $$;

create or replace function public.trace_create_dpl_v1(p_input jsonb,p_carton_ids uuid[],p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare f text:=md5(p_input::text||p_carton_ids::text); prior record; d public.ols_dpl_documents; cid uuid; pos int:=0; links jsonb:='[]'; link public.ols_dpl_cartons; result jsonb;
begin
  perform public.trace_assert_role_v1('dispatch'); perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  select payload_fingerprint,response into prior from public.ols_trace_mutation_receipts where idempotency_key=p_idempotency_key;
  if found then if prior.payload_fingerprint<>f then raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode='P0001'; end if; return prior.response; end if;
  if coalesce(array_length(p_carton_ids,1),0)=0 or exists(select 1 from unnest(p_carton_ids) x left join public.ols_cartons c on c.id=x where c.id is null or c.status<>'packed') then raise exception 'DPL_CARTON_MEMBERSHIP_REJECTED' using errcode='P0001'; end if;
  insert into public.ols_dpl_documents(dpl_no,order_ref,customer_name,destination,transport_mode,total_cartons,total_gross,total_net,status,prepared_by)
  values(p_input->>'dpl_no',p_input->>'order_ref',p_input->>'customer_name',p_input->>'destination',p_input->>'transport_mode',array_length(p_carton_ids,1),(p_input->>'total_gross')::numeric,(p_input->>'total_net')::numeric,'open',auth.uid()) returning * into d;
  foreach cid in array p_carton_ids loop pos:=pos+1; insert into public.ols_dpl_cartons(dpl_id,carton_id,position) values(d.id,cid,pos) returning * into link; links:=links||to_jsonb(link); end loop;
  result:=jsonb_build_object('dpl',to_jsonb(d),'links',links); insert into public.ols_audit_logs(action,entity_type,entity_id,user_id,details,idempotency_key) values('trace_dpl_created','dpl',d.id,auth.uid(),jsonb_build_object('carton_ids',p_carton_ids),p_idempotency_key);
  insert into public.ols_trace_mutation_receipts values(default,p_idempotency_key,'create_dpl',f,result,auth.uid(),default); return result;
end $$;

create or replace function public.trace_add_carton_to_pi_v1(p_carton_id uuid,p_pi_id uuid,p_pi_no text,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare f text:=md5(concat_ws('|',p_carton_id,p_pi_id,p_pi_no)); prior record; c public.ols_cartons; p public.ols_finance_pi; dpl uuid; link_id uuid; result jsonb;
begin
  perform public.trace_assert_role_v1('finance'); perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  select payload_fingerprint,response into prior from public.ols_trace_mutation_receipts where idempotency_key=p_idempotency_key;
  if found then if prior.payload_fingerprint<>f then raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode='P0001'; end if; return prior.response; end if;
  select * into c from public.ols_cartons where id=p_carton_id for update; if not found then raise exception 'CARTON_NOT_FOUND' using errcode='P0001'; end if;
  select dc.dpl_id into dpl from public.ols_dpl_cartons dc where dc.carton_id=c.id;
  if dpl is null then raise exception 'UNLINKED_DPL_CARTON_REJECTED' using errcode='P0001'; end if;
  if p_pi_id is null then insert into public.ols_finance_pi(pi_no,dpl_id,order_ref,customer_name,status,created_by) values(p_pi_no,dpl,c.order_ref,c.customer_name,'pending',auth.uid()) returning * into p;
  else select * into p from public.ols_finance_pi where id=p_pi_id for update; if not found or p.status<>'pending' or p.dpl_id is distinct from dpl then raise exception 'PI_DPL_MEMBERSHIP_REJECTED' using errcode='P0001'; end if; end if;
  insert into public.ols_finance_pi_cartons(pi_id,carton_id) values(p.id,c.id) returning id into link_id; update public.ols_cartons set status='finance_received' where id=c.id returning * into c;
  result:=jsonb_build_object('pi',to_jsonb(p),'carton',to_jsonb(c),'link_id',link_id); insert into public.ols_audit_logs(action,entity_type,entity_id,user_id,details,idempotency_key) values('trace_pi_carton_added','finance_pi',p.id,auth.uid(),jsonb_build_object('carton_id',c.id,'dpl_id',dpl),p_idempotency_key);
  insert into public.ols_trace_mutation_receipts values(default,p_idempotency_key,'add_carton_to_pi',f,result,auth.uid(),default); return result;
end $$;

create or replace function public.trace_clear_pi_v1(p_pi_id uuid,p_invoice_ref text,p_lines jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare f text:=md5(concat_ws('|',p_pi_id,p_invoice_ref,p_lines::text)); prior record; p public.ols_finance_pi; item jsonb; result jsonb;
begin
  perform public.trace_assert_role_v1('finance'); perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  select payload_fingerprint,response into prior from public.ols_trace_mutation_receipts where idempotency_key=p_idempotency_key;
  if found then if prior.payload_fingerprint<>f then raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode='P0001'; end if; return prior.response; end if;
  select * into p from public.ols_finance_pi where id=p_pi_id for update; if not found or p.status<>'pending' or nullif(btrim(p_invoice_ref),'') is null then raise exception 'PI_NOT_CLEARABLE' using errcode='P0001'; end if;
  if not exists(select 1 from public.ols_finance_pi_cartons pc join public.ols_dpl_cartons dc on dc.carton_id=pc.carton_id and dc.dpl_id=p.dpl_id where pc.pi_id=p.id) then raise exception 'UNPROVEN_PI_DPL_MEMBERSHIP' using errcode='P0001'; end if;
  update public.ols_finance_pi set status='cleared',cleared_at=now(),invoice_ref=p_invoice_ref where id=p.id returning * into p;
  update public.ols_cartons c set status='invoiced' from public.ols_finance_pi_cartons pc where pc.pi_id=p.id and pc.carton_id=c.id;
  for item in select value from jsonb_array_elements(p_lines) loop insert into public.ols_finance_pi_lines(pi_id,sku,product_name,quantity,net_weight,gross_weight) values(p.id,item->>'sku',item->>'product_name',(item->>'quantity')::numeric,(item->>'net_weight')::numeric,(item->>'gross_weight')::numeric); end loop;
  result:=to_jsonb(p); insert into public.ols_audit_logs(action,entity_type,entity_id,user_id,details,idempotency_key) values('trace_pi_cleared','finance_pi',p.id,auth.uid(),jsonb_build_object('invoice_ref',p_invoice_ref),p_idempotency_key);
  insert into public.ols_trace_mutation_receipts values(default,p_idempotency_key,'clear_pi',f,result,auth.uid(),default); return result;
end $$;

create or replace function public.trace_create_shipping_label_v1(p_input jsonb,p_idempotency_key text)
returns jsonb language plpgsql security definer set search_path=public,pg_temp as $$
declare f text:=md5(p_input::text); prior record; c public.ols_cartons; p public.ols_finance_pi; s public.ols_shipping_labels; result jsonb;
begin
  perform public.trace_assert_role_v1('dispatch'); perform pg_advisory_xact_lock(hashtextextended(p_idempotency_key,0));
  select payload_fingerprint,response into prior from public.ols_trace_mutation_receipts where idempotency_key=p_idempotency_key;
  if found then if prior.payload_fingerprint<>f then raise exception 'IDEMPOTENCY_KEY_CONFLICT' using errcode='P0001'; end if; return prior.response; end if;
  select * into c from public.ols_cartons where id=(p_input->>'carton_id')::uuid for update; select * into p from public.ols_finance_pi where id=(p_input->>'pi_id')::uuid and status='cleared';
  if c.id is null or p.id is null or c.status<>'invoiced' or not exists(select 1 from public.ols_finance_pi_cartons pc join public.ols_dpl_cartons dc on dc.carton_id=pc.carton_id and dc.dpl_id=p.dpl_id where pc.pi_id=p.id and pc.carton_id=c.id) then raise exception 'UNPROVEN_PI_CARTON_MEMBERSHIP' using errcode='P0001'; end if;
  insert into public.ols_shipping_labels(shipping_no,carton_id,pi_id,consignor,consignee,address,invoice_ref,qr_ref,status) values(p_input->>'shipping_no',c.id,p.id,p_input->>'consignor',p_input->>'consignee',p_input->>'address',p.invoice_ref,p_input->>'qr_ref','generated') returning * into s;
  update public.ols_cartons set status='shipping_labelled' where id=c.id;
  result:=to_jsonb(s); insert into public.ols_audit_logs(action,entity_type,entity_id,user_id,details,idempotency_key) values('trace_shipping_label_created','shipping_label',s.id,auth.uid(),jsonb_build_object('carton_id',c.id,'pi_id',p.id),p_idempotency_key);
  insert into public.ols_trace_mutation_receipts values(default,p_idempotency_key,'create_shipping_label',f,result,auth.uid(),default); return result;
end $$;

-- Remove blanket authenticated mutation policies. Direct writes fail closed;
-- governed SECURITY DEFINER RPCs perform role checks before any mutation.
do $$ declare r record; p record; begin
  for r in select tablename from pg_tables where schemaname='public' and tablename like 'ols\_%' escape '\' loop
    execute format('alter table public.%I enable row level security',r.tablename);
    execute format('alter table public.%I force row level security',r.tablename);
    execute format('drop policy if exists "ols_auth_write" on public.%I',r.tablename);
    execute format('drop policy if exists "ols_auth_update" on public.%I',r.tablename);
    execute format('drop policy if exists "ols_auth_delete" on public.%I',r.tablename);
    for p in select policyname from pg_policies where schemaname='public' and tablename=r.tablename and cmd in ('INSERT','UPDATE','DELETE','ALL') loop
      execute format('drop policy %I on public.%I',p.policyname,r.tablename);
    end loop;
    execute format('drop policy if exists "trace_internal_read" on public.%I',r.tablename);
    execute format('create policy "trace_internal_read" on public.%I for select to authenticated using (public.is_internal_staff(auth.uid()))',r.tablename);
  end loop;
end $$;

revoke all on table public.ols_trace_mutation_receipts from public,anon,authenticated;
revoke all on function public.trace_role_allowed_v1(text) from public,anon;
revoke all on function public.trace_assert_role_v1(text) from public,anon;
revoke all on function public.trace_audit_immutable_v1() from public,anon,authenticated;
grant execute on function public.trace_role_allowed_v1(text),public.trace_assert_role_v1(text) to authenticated,service_role;
revoke all on function public.trace_create_production_v1(jsonb,jsonb,text) from public,anon;
revoke all on function public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text) from public,anon;
revoke all on function public.trace_create_dpl_v1(jsonb,uuid[],text) from public,anon;
revoke all on function public.trace_add_carton_to_pi_v1(uuid,uuid,text,text) from public,anon;
revoke all on function public.trace_clear_pi_v1(uuid,text,jsonb,text) from public,anon;
revoke all on function public.trace_create_shipping_label_v1(jsonb,text) from public,anon;
grant execute on function public.trace_create_production_v1(jsonb,jsonb,text) to authenticated,service_role;
grant execute on function public.trace_finalize_carton_v1(uuid,numeric,numeric,boolean,text) to authenticated,service_role;
grant execute on function public.trace_create_dpl_v1(jsonb,uuid[],text) to authenticated,service_role;
grant execute on function public.trace_add_carton_to_pi_v1(uuid,uuid,text,text) to authenticated,service_role;
grant execute on function public.trace_clear_pi_v1(uuid,text,jsonb,text) to authenticated,service_role;
grant execute on function public.trace_create_shipping_label_v1(jsonb,text) to authenticated,service_role;
