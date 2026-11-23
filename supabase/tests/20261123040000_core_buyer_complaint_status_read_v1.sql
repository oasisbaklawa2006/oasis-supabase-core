-- Contract and behaviour tests for 20261123040000_core_buyer_complaint_status_read_v1.sql
-- (ASM-CORE-BUYER-COMPLAINT-STATUS-READ-1E).
--
-- Live sections run as real JWT identities under `set local role authenticated`; a regression raises and aborts the
-- file. Fixtures use the shipped bridge RPC (buyer intake), the staff return-link command and the real Finance AAL2
-- resolution RPC, so the status function is read against genuine data. Everything is rolled back.
begin;

select plan(15);

create schema bsr_t;
grant usage on schema bsr_t to public;

create function bsr_t.claims(p_sub uuid, p_aal text default 'aal1') returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_sub::text, 'role', 'authenticated', 'aal', p_aal)::text, true)
$$;

create function bsr_t.expect_error(p_sql text, p_state text, p_msg text) returns void
language plpgsql as $$
declare v_state text; v_msg text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_state = returned_sqlstate, v_msg = message_text;
    if v_state is distinct from p_state or v_msg not like p_msg then
      raise exception 'EXPECTED % / % BUT GOT % / % FOR: %', p_state, p_msg, v_state, v_msg, p_sql;
    end if;
    return;
  end;
  raise exception 'EXPECTED ERROR % / % BUT STATEMENT SUCCEEDED: %', p_state, p_msg, p_sql;
end $$;

create function bsr_t.gv(p_name text) returns uuid language sql stable as $$
  select current_setting('bsr.' || p_name)::uuid
$$;

create function bsr_t.mk_order(p_company uuid) returns uuid
language plpgsql as $$
declare
  v_order uuid := gen_random_uuid();
  v_inv uuid := gen_random_uuid();
  v_corr text := 'bsr-' || gen_random_uuid()::text;
begin
  insert into public.orders (id, order_number, order_origin, company_id)
  values (v_order, 'BS-' || substr(v_order::text, 1, 8), 'CUSTOMER_APP', p_company);
  insert into public.final_invoices (
    id, commercial_version_id, company_id, correlation_id, document_reference, finance_dpl_receipt_id, gross_total,
    idempotency_key, invoice_date, invoice_fingerprint, invoice_number, issued_by, issued_role, order_id,
    proforma_invoice_id, reason, status, tax_total, taxable_total
  ) values (
    v_inv, gen_random_uuid(), p_company, v_corr, 'DOC-' || v_corr, gen_random_uuid(), 100,
    'inv-' || v_corr, (now() at time zone 'Asia/Kolkata')::date, repeat('a', 64), 'INV-' || v_corr,
    gen_random_uuid(), 'FINANCE_HEAD', v_order, gen_random_uuid(), 'status fixture', 'ISSUED', 0, 100
  );
  insert into public.dispatch_proof_packets (
    correlation_id, dispatched_at, evidence_references, final_invoice_id, finance_dispatch_clearance_event_id,
    finance_dpl_receipt_id, gate_decision_ids, idempotency_key, order_id, proof_fingerprint, recorded_by,
    recorded_role, transport_snapshot
  ) values (
    v_corr, now(), '[]'::jsonb, v_inv, gen_random_uuid(), gen_random_uuid(), '[]'::jsonb, 'dp-' || v_corr, v_order,
    repeat('b', 64), gen_random_uuid(), 'DISPATCH_HEAD', '{}'::jsonb
  );
  return v_order;
end $$;

-- Return case in a given arrival state. States that need receipt evidence satisfy b2b_return_receipt_evidence_check.
create function bsr_t.mk_return(p_order uuid, p_state text) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  if p_state in ('conditionally_received', 'partially_received', 'quarantined') then
    insert into public.b2b_return_arrival_cases (
      id, case_number, order_id, arrival_state, cartons_presented, external_condition, correlation_id,
      gate_evidence_refs, unloading_authorised_by, quarantine_location, transporter_ack_ref)
    values (v_id, 'RC-' || substr(v_id::text, 1, 8), p_order, p_state, 2, 'intact', 'rc-' || v_id::text,
      '["gate-photo"]'::jsonb, gen_random_uuid(), 'Q-BAY-1', 'ack-1');
  else
    insert into public.b2b_return_arrival_cases (id, case_number, order_id, arrival_state, cartons_presented, external_condition, correlation_id)
    values (v_id, 'RC-' || substr(v_id::text, 1, 8), p_order, p_state, 2, 'intact', 'rc-' || v_id::text);
  end if;
  return v_id;
end $$;

grant execute on all functions in schema bsr_t to public;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Catalogue / privilege contract
-- ---------------------------------------------------------------------------------------------------------------
select has_function('public', 'customer_commercial_complaint_status_v1', array[]::text[], 'buyer status RPC exists');

select ok(
  has_function_privilege('authenticated', 'public.customer_commercial_complaint_status_v1()', 'EXECUTE')
  and not has_function_privilege('anon', 'public.customer_commercial_complaint_status_v1()', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.customer_commercial_complaint_status_v1()', 'EXECUTE'),
  'authenticated-only: no anon and no service_role execute'
);

select ok(
  (select p.provolatile = 's' and p.prosecdef
     from pg_proc p where p.oid = 'public.customer_commercial_complaint_status_v1()'::regprocedure)
  and pg_get_functiondef('public.customer_commercial_complaint_status_v1()'::regprocedure) like '%search_path%',
  'read-only (STABLE), SECURITY DEFINER with a pinned search_path'
);

select ok(
  (select proargnames from pg_proc where oid = 'public.customer_commercial_complaint_status_v1()'::regprocedure)
  = array['support_ticket_id', 'order_id', 'order_number', 'complaint_id', 'complaint_type', 'complaint_filed_at',
          'complaint_deadline', 'complaint_status', 'return_receipt_status', 'return_case_count', 'finance_status',
          'finance_outcome', 'finance_amount', 'finance_resolved_at'],
  'result columns are exactly the Buyer-safe contract'
);

select ok(
  not exists (
    select 1 from unnest((select proargnames from pg_proc where oid = 'public.customer_commercial_complaint_status_v1()'::regprocedure)) as n(name)
    where n.name ~ '(actor|reason|correlation|idempotency|evidence|document|payment|wallet|notes|filed_by|linked_by|role)'
  ),
  'no actor, reason, key, evidence, document, payment or note column can be returned'
);

select ok(
  pg_get_functiondef('public.customer_commercial_complaint_status_v1()'::regprocedure) like '%customer_buyer_eligible_company_id%',
  'company scope comes from the canonical eligible-Buyer gate, never a client argument'
);

select ok(
  has_function_privilege('authenticated', 'public.get_commercial_complaint_handoff_facts_v1(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.get_commercial_complaint_handoff_facts_v1(uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.get_commercial_complaint_handoff_facts_v1(uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)', 'EXECUTE'),
  'shipped bridge, handoff-facts and resolution RPCs keep their signatures and grants'
);

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Fixtures (through the shipped RPCs)
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_co_a uuid; v_co_b uuid; v_i integer; v_name text;
  v_orders text[] := array['o1', 'o2', 'o3', 'o4', 'o5', 'o6'];
begin
  set local session_replication_role = replica;
  insert into public.companies (business_name, status) values ('Status Co A', 'active') returning id into v_co_a;
  insert into public.companies (business_name, status) values ('Status Co B', 'active') returning id into v_co_b;
  perform set_config('bsr.co_a', v_co_a::text, true);
  perform set_config('bsr.co_b', v_co_b::text, true);
  foreach v_name in array array['buyer_a', 'buyer_b', 'buyer_unapproved', 'support', 'finance', 'sales'] loop
    perform set_config('bsr.' || v_name, gen_random_uuid()::text, true);
  end loop;
  insert into auth.users (id, email) values
    (bsr_t.gv('buyer_a'), 'bsr-a@example.invalid'), (bsr_t.gv('buyer_b'), 'bsr-b@example.invalid'),
    (bsr_t.gv('buyer_unapproved'), 'bsr-u@example.invalid'), (bsr_t.gv('support'), 'bsr-s@example.invalid'),
    (bsr_t.gv('finance'), 'bsr-f@example.invalid'), (bsr_t.gv('sales'), 'bsr-x@example.invalid');
  insert into public.profiles (id, company_id, role, is_approved, status, email) values
    (bsr_t.gv('buyer_a'), v_co_a, 'b2b_buyer', true, 'approved', 'bsr-a@example.invalid'),
    (bsr_t.gv('buyer_b'), v_co_b, 'b2b_buyer', true, 'approved', 'bsr-b@example.invalid'),
    (bsr_t.gv('buyer_unapproved'), v_co_a, 'b2b_buyer', false, 'pending', 'bsr-u@example.invalid');
  insert into public.users (id, email, role, is_active) values
    (bsr_t.gv('support'), 'bsr-s@example.invalid', 'support_executive', true),
    (bsr_t.gv('finance'), 'bsr-f@example.invalid', 'finance_exec', true),
    (bsr_t.gv('sales'), 'bsr-x@example.invalid', 'sales_executive', true);
  foreach v_name in array v_orders loop
    perform set_config('bsr.' || v_name, bsr_t.mk_order(v_co_a)::text, true);
  end loop;
  perform set_config('bsr.ob1', bsr_t.mk_order(v_co_b)::text, true);
  set local session_replication_role = default;

  -- Buyer A files six claims and buyer B one, all through the shipped bridge RPC.
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  v_i := 0;
  foreach v_name in array v_orders loop
    v_i := v_i + 1;
    perform * from public.submit_customer_commercial_complaint_v1(
      'bsr-claim-' || v_name, bsr_t.gv(v_name), 'DAMAGE', 'Status fixture claim ' || v_name,
      jsonb_build_array('ev-' || v_name));
    -- Space the filing times so the newest-first ordering is deterministic.
    reset role;
    set local session_replication_role = replica;
    update public.commercial_complaints set filed_at = now() + (v_i || ' minutes')::interval
      where order_id = bsr_t.gv(v_name);
    set local session_replication_role = default;
    perform bsr_t.claims(bsr_t.gv('buyer_a'));
    set local role authenticated;
  end loop;
  reset role;
  perform bsr_t.claims(bsr_t.gv('buyer_b'));
  set local role authenticated;
  perform * from public.submit_customer_commercial_complaint_v1(
    'bsr-claim-ob1', bsr_t.gv('ob1'), 'SHORTAGE', 'Status fixture claim for company B', '["ev-b"]'::jsonb);
  reset role;

  foreach v_name in array v_orders || array['ob1'] loop
    perform set_config('bsr.c_' || v_name,
      (select c.id::text from public.commercial_complaints c where c.order_id = bsr_t.gv(v_name)), true);
  end loop;
end $$;
select pass('fixtures built through the shipped bridge RPC: 6 claims for company A, 1 for company B');

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Scope: who sees what
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_n bigint; v_row record; v_name text;
begin
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  select count(*) into v_n from public.customer_commercial_complaint_status_v1();
  if v_n <> 6 then raise exception 'buyer A must see exactly its own 6 complaints, saw %', v_n; end if;
  if exists (select 1 from public.customer_commercial_complaint_status_v1() where complaint_id = bsr_t.gv('c_ob1')) then
    raise exception 'buyer A saw company B complaint';
  end if;

  perform bsr_t.claims(bsr_t.gv('buyer_b'));
  select count(*) into v_n from public.customer_commercial_complaint_status_v1();
  if v_n <> 1 then raise exception 'buyer B must see exactly its own complaint, saw %', v_n; end if;
  select * into v_row from public.customer_commercial_complaint_status_v1();
  if v_row.complaint_id is distinct from bsr_t.gv('c_ob1') or v_row.complaint_type <> 'SHORTAGE' then
    raise exception 'buyer B row wrong: %', row_to_json(v_row);
  end if;

  -- Not an eligible Buyer: unapproved buyer, staff (they have the staff RPC), a caller with no identity.
  foreach v_name in array array['buyer_unapproved', 'support', 'finance', 'sales'] loop
    perform bsr_t.claims(bsr_t.gv(v_name), 'aal2');
    select count(*) into v_n from public.customer_commercial_complaint_status_v1();
    if v_n <> 0 then raise exception '% must get no rows from the Buyer RPC, saw %', v_name, v_n; end if;
  end loop;
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  select count(*) into v_n from public.customer_commercial_complaint_status_v1();
  if v_n <> 0 then raise exception 'no identity must get no rows'; end if;
  set local role anon;
  perform bsr_t.expect_error('select * from public.customer_commercial_complaint_status_v1()', '42501', 'permission denied%');
  reset role;
end $$;
select pass('scope: each Buyer sees only its own company; unapproved buyers, staff, no identity and anon see nothing');

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Pending complaint: deadline, status, no return, Finance pending
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_row record; v_first uuid; v_last uuid;
begin
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  select * into v_row from public.customer_commercial_complaint_status_v1() where complaint_id = bsr_t.gv('c_o1');
  if not found
     or v_row.order_id is distinct from bsr_t.gv('o1')
     or v_row.order_number is null or v_row.order_number not like 'BS-%'
     or v_row.complaint_type is distinct from 'DAMAGE'
     or v_row.complaint_status is distinct from 'OPEN'
     or v_row.return_receipt_status is distinct from 'NO_RETURN_RECORDED'
     or v_row.return_case_count is distinct from 0
     or v_row.finance_status is distinct from 'PENDING_FINANCE_REVIEW'
     or v_row.finance_outcome is not null or v_row.finance_amount is not null or v_row.finance_resolved_at is not null
     or v_row.support_ticket_id is null then
    raise exception 'pending complaint row wrong: %', row_to_json(v_row);
  end if;
  if v_row.complaint_deadline is distinct from
     public.complaint_deadline_from_invoice_v1((now() at time zone 'Asia/Kolkata')::date) then
    raise exception 'deadline must be the canonical invoice-date deadline, got %', v_row.complaint_deadline;
  end if;
  if v_row.support_ticket_id is distinct from
     (select l.support_ticket_id from public.support_commercial_complaint_links l where l.complaint_id = bsr_t.gv('c_o1')) then
    raise exception 'ticket id must be the linked ticket';
  end if;
  select complaint_id into v_first from public.customer_commercial_complaint_status_v1() limit 1;
  select complaint_id into v_last from (select complaint_id, row_number() over () rn from public.customer_commercial_complaint_status_v1()) t order by rn desc limit 1;
  if v_first is distinct from bsr_t.gv('c_o6') or v_last is distinct from bsr_t.gv('c_o1') then
    raise exception 'rows must be newest first';
  end if;
  reset role;
end $$;
select pass('pending complaint: canonical deadline, OPEN, no return recorded, Finance pending with no outcome or amount; newest first');

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Physical return receipt (coarse, never acceptance)
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_rc_arr uuid; v_rc_recv uuid; v_rc_refused uuid; v_rc_arr2 uuid; v_row record;
begin
  set local session_replication_role = replica;
  v_rc_arr := bsr_t.mk_return(bsr_t.gv('o1'), 'awaiting_gate_decision');
  v_rc_recv := bsr_t.mk_return(bsr_t.gv('o1'), 'conditionally_received');
  v_rc_refused := bsr_t.mk_return(bsr_t.gv('o2'), 'rejected_at_gate');
  v_rc_arr2 := bsr_t.mk_return(bsr_t.gv('o3'), 'vehicle_held');
  set local session_replication_role = default;

  -- Link through the real staff command.
  perform bsr_t.claims(bsr_t.gv('support'));
  set local role authenticated;
  perform * from public.link_return_case_to_commercial_complaint_v1(v_rc_arr, bsr_t.gv('c_o1'));
  perform * from public.link_return_case_to_commercial_complaint_v1(v_rc_recv, bsr_t.gv('c_o1'));
  perform * from public.link_return_case_to_commercial_complaint_v1(v_rc_refused, bsr_t.gv('c_o2'));
  perform * from public.link_return_case_to_commercial_complaint_v1(v_rc_arr2, bsr_t.gv('c_o3'));
  reset role;

  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  for v_row in select * from public.customer_commercial_complaint_status_v1() loop
    if v_row.complaint_id = bsr_t.gv('c_o1') and (v_row.return_receipt_status, v_row.return_case_count) is distinct from ('RETURN_PHYSICALLY_RECEIVED', 2) then
      raise exception 'received must win over arrival-recorded: %', row_to_json(v_row);
    elsif v_row.complaint_id = bsr_t.gv('c_o2') and (v_row.return_receipt_status, v_row.return_case_count) is distinct from ('RETURN_REFUSED_AT_GATE', 1) then
      raise exception 'refused at gate wrong: %', row_to_json(v_row);
    elsif v_row.complaint_id = bsr_t.gv('c_o3') and (v_row.return_receipt_status, v_row.return_case_count) is distinct from ('RETURN_ARRIVAL_RECORDED', 1) then
      raise exception 'arrival recorded wrong: %', row_to_json(v_row);
    elsif v_row.complaint_id in (bsr_t.gv('c_o4'), bsr_t.gv('c_o5'), bsr_t.gv('c_o6'))
          and (v_row.return_receipt_status, v_row.return_case_count) is distinct from ('NO_RETURN_RECORDED', 0) then
      raise exception 'unlinked complaint must show no return: %', row_to_json(v_row);
    end if;
  end loop;
  -- A physical receipt is never reported as a claim outcome: Finance and complaint status are unaffected.
  select * into v_row from public.customer_commercial_complaint_status_v1() where complaint_id = bsr_t.gv('c_o1');
  if v_row.complaint_status <> 'OPEN' or v_row.finance_status <> 'PENDING_FINANCE_REVIEW' then
    raise exception 'a received return must not change complaint or Finance status: %', row_to_json(v_row);
  end if;
  reset role;
end $$;
select pass('return receipt is a coarse state (received > arrival recorded > refused > none) and never changes claim or Finance status');

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Finance outcomes through the real AAL2 resolution RPC
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_row record;
begin
  perform bsr_t.claims(bsr_t.gv('finance'), 'aal2');
  set local role authenticated;
  perform * from public.resolve_commercial_complaint_v1(bsr_t.gv('c_o2'), 'NO_FINANCIAL_ACTION', 0, null, null, null,
    'internal decision text SECRET-REASON', 'corr-secret-1', 'res-secret-1');
  perform * from public.resolve_commercial_complaint_v1(bsr_t.gv('c_o3'), 'CREDIT_NOTE', 1500.50, 'CN-SECRET-77',
    'DOC-SECRET-REF', null, 'internal decision text SECRET-REASON', 'corr-secret-2', 'res-secret-2');
  perform * from public.resolve_commercial_complaint_v1(bsr_t.gv('c_o4'), 'REFUND_TO_BANK', 700, null, null,
    'BANK-SECRET-REF', 'internal decision text SECRET-REASON', 'corr-secret-3', 'res-secret-3');
  perform * from public.resolve_commercial_complaint_v1(bsr_t.gv('c_o5'), 'TRANSPORTER_RECOVERY', 250, null, null, null,
    'internal decision text SECRET-REASON', 'corr-secret-4', 'res-secret-4');
  perform * from public.resolve_commercial_complaint_v1(bsr_t.gv('c_o6'), 'REPLACEMENT_CHARGEABLE', 100, null, null, null,
    'internal decision text SECRET-REASON', 'corr-secret-5', 'res-secret-5');
  reset role;

  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  for v_row in select * from public.customer_commercial_complaint_status_v1() loop
    if v_row.complaint_id = bsr_t.gv('c_o1') then
      if v_row.finance_status <> 'PENDING_FINANCE_REVIEW' or v_row.finance_outcome is not null then
        raise exception 'unresolved complaint must stay pending: %', row_to_json(v_row);
      end if;
    elsif v_row.complaint_id = bsr_t.gv('c_o2') then
      if (v_row.complaint_status, v_row.finance_status, v_row.finance_outcome) is distinct from ('RESOLVED', 'RESOLVED', 'NO_FINANCIAL_ACTION')
         or v_row.finance_amount is not null or v_row.finance_resolved_at is null then
        raise exception 'no-financial-action wrong: %', row_to_json(v_row);
      end if;
    elsif v_row.complaint_id = bsr_t.gv('c_o3') then
      if (v_row.finance_status, v_row.finance_outcome, v_row.finance_amount) is distinct from ('RESOLVED', 'CREDIT_NOTE', 1500.50::numeric) then
        raise exception 'credit note wrong: %', row_to_json(v_row);
      end if;
    elsif v_row.complaint_id = bsr_t.gv('c_o4') then
      if (v_row.finance_status, v_row.finance_outcome, v_row.finance_amount) is distinct from ('RESOLVED', 'REFUND_TO_BANK', 700::numeric) then
        raise exception 'bank refund wrong: %', row_to_json(v_row);
      end if;
    elsif v_row.complaint_id = bsr_t.gv('c_o5') then
      -- Internal recovery is never named to a Buyer and never carries an amount.
      if (v_row.finance_status, v_row.finance_outcome) is distinct from ('RESOLVED', 'OTHER_RESOLUTION') or v_row.finance_amount is not null then
        raise exception 'internal recovery must collapse to OTHER_RESOLUTION without an amount: %', row_to_json(v_row);
      end if;
    elsif v_row.complaint_id = bsr_t.gv('c_o6') then
      if (v_row.finance_status, v_row.finance_outcome) is distinct from ('RESOLVED', 'REPLACEMENT_CHARGEABLE') or v_row.finance_amount is not null then
        raise exception 'chargeable replacement wrong: %', row_to_json(v_row);
      end if;
    end if;
  end loop;
  reset role;
end $$;
select pass('Finance outcomes: whitelisted names, amounts only for credit/refund, internal recovery collapses to OTHER_RESOLUTION');

-- ---------------------------------------------------------------------------------------------------------------
-- 7. No internal data leaks, and a resolved status survives tied event timestamps
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_blob text; v_row record;
begin
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  select string_agg(row_to_json(t)::text, ' ') into v_blob from public.customer_commercial_complaint_status_v1() t;
  reset role;
  if v_blob is null then raise exception 'expected rows'; end if;
  if v_blob ~* '(SECRET|corr-|res-|bsr-claim|ev-o|quarantine|Q-BAY|ack-1|gate-photo|TRANSPORTER_RECOVERY|finance_exec|support_executive)' then
    raise exception 'internal data leaked to a Buyer: %', v_blob;
  end if;

  -- Tie every event timestamp and make the OPEN event sort last by id: status must still follow the adjustment.
  set local session_replication_role = replica;
  update public.commercial_complaint_events set created_at = now() where complaint_id = bsr_t.gv('c_o2');
  update public.commercial_complaint_events set id = 'ffffffff-ffff-ffff-ffff-ffffffffffff'
    where complaint_id = bsr_t.gv('c_o2') and status = 'OPEN';
  set local session_replication_role = default;
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  select * into v_row from public.customer_commercial_complaint_status_v1() where complaint_id = bsr_t.gv('c_o2');
  reset role;
  if v_row.complaint_status is distinct from 'RESOLVED' then
    raise exception 'tied timestamps must not make a resolved complaint report %', v_row.complaint_status;
  end if;
end $$;
select pass('no internal reasons, keys, references, evidence or quarantine data leak; RESOLVED holds under tied event timestamps');

-- ---------------------------------------------------------------------------------------------------------------
-- 8. Read-only, and unlinked complaints are not projected
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_before text; v_after text; v_complaint uuid := gen_random_uuid();
begin
  select md5(string_agg(x, '|' order by x)) into v_before from (
    select 'c' || count(*) from public.commercial_complaints union all
    select 'l' || count(*) from public.support_commercial_complaint_links union all
    select 'r' || count(*) from public.commercial_complaint_return_links union all
    select 'a' || count(*) from public.commercial_adjustments union all
    select 'e' || count(*) from public.commercial_complaint_events union all
    select 't' || count(*) from public.support_tickets) q(x);
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  perform count(*) from public.customer_commercial_complaint_status_v1();
  reset role;
  select md5(string_agg(x, '|' order by x)) into v_after from (
    select 'c' || count(*) from public.commercial_complaints union all
    select 'l' || count(*) from public.support_commercial_complaint_links union all
    select 'r' || count(*) from public.commercial_complaint_return_links union all
    select 'a' || count(*) from public.commercial_adjustments union all
    select 'e' || count(*) from public.commercial_complaint_events union all
    select 't' || count(*) from public.support_tickets) q(x);
  if v_before is distinct from v_after then raise exception 'the status read changed data'; end if;

  -- A complaint with no support-ticket link (e.g. filed another way) is not part of this projection.
  set local session_replication_role = replica;
  insert into public.commercial_complaints (id, order_id, company_id, dispatch_proof_id, complaint_type, description,
    evidence_references, complaint_deadline, filed_by, filed_role, correlation_id, idempotency_key)
  values (v_complaint, bsr_t.gv('o1'), bsr_t.gv('co_a'), (select id from public.dispatch_proof_packets limit 1), 'DAMAGE',
    'Unlinked complaint', '["x"]'::jsonb, now() + interval '5 days', bsr_t.gv('buyer_a'), 'b2b_buyer', 'unlinked-1', 'unlinked-key-1');
  set local session_replication_role = default;
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  if exists (select 1 from public.customer_commercial_complaint_status_v1() where complaint_id = v_complaint) then
    raise exception 'an unlinked complaint must not be projected';
  end if;
  reset role;
end $$;
select pass('the read changes no data, and a complaint with no support-ticket link is not projected');

-- ---------------------------------------------------------------------------------------------------------------
-- 9. Shipped objects keep working and keep their staff-only posture
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_n bigint;
begin
  perform bsr_t.claims(bsr_t.gv('buyer_a'));
  set local role authenticated;
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(
    (select l.support_ticket_id from public.support_commercial_complaint_links l where l.complaint_id = bsr_t.gv('c_o1')));
  if v_n <> 0 then raise exception 'the staff handoff RPC must remain staff-only (buyer saw % rows)', v_n; end if;
  reset role;
  perform bsr_t.claims(bsr_t.gv('support'));
  set local role authenticated;
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(
    (select l.support_ticket_id from public.support_commercial_complaint_links l where l.complaint_id = bsr_t.gv('c_o1')));
  if v_n <> 1 then raise exception 'the staff handoff RPC must still serve Support'; end if;
  reset role;
end $$;
select pass('the staff handoff RPC is unchanged: still empty for a Buyer, still served to Support');

select * from finish();
rollback;
