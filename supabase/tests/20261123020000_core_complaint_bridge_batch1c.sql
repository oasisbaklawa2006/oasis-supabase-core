-- Contract and behaviour tests for 20261123020000_core_complaint_bridge_batch1c.sql (ASM-CORE-COMPLAINT-BRIDGE-1C).
--
-- Live sections run as real JWT identities under `set local role authenticated`; failures raise and abort the file.
-- Fixture rows are inserted with FK/trigger replication disabled (the established Core test pattern); every RPC under
-- test then runs with normal trigger and RLS semantics. Everything is rolled back.
begin;

select plan(33);

-- ---------------------------------------------------------------------------------------------------------------
-- Test scaffolding (rolled back with the transaction)
-- ---------------------------------------------------------------------------------------------------------------
create schema bridge_t;
grant usage on schema bridge_t to public;

create function bridge_t.claims(p_sub uuid, p_aal text default 'aal1') returns void
language sql as $$
  select set_config('request.jwt.claims',
    json_build_object('sub', p_sub::text, 'role', 'authenticated', 'aal', p_aal)::text, true)
$$;

create function bridge_t.expect_error(p_sql text, p_state text, p_msg text) returns void
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

create function bridge_t.call_sql(
  p_key text, p_order uuid, p_type text, p_desc text, p_ev jsonb, p_sku text default null, p_qty integer default null
) returns text language sql immutable as $$
  select format(
    'select * from public.submit_customer_commercial_complaint_v1(%L, %L::uuid, %L, %L, %L::jsonb, %L, %L::integer)',
    p_key, p_order, p_type, p_desc, p_ev, p_sku, p_qty)
$$;

create function bridge_t.gv(p_name text) returns uuid language sql stable as $$
  select current_setting('bridge.' || p_name)::uuid
$$;

-- Order + ISSUED final invoice + dispatch proof. p_age is the invoice age in IST days (window = invoice day + 10).
create function bridge_t.mk_order(p_company uuid, p_age integer) returns uuid
language plpgsql as $$
declare
  v_order uuid := gen_random_uuid();
  v_inv uuid := gen_random_uuid();
  v_corr text := 'bridge-' || gen_random_uuid()::text;
begin
  insert into public.orders (id, order_number, order_origin, company_id)
  values (v_order, 'BR-' || substr(v_order::text, 1, 8), 'CUSTOMER_APP', p_company);
  insert into public.final_invoices (
    id, commercial_version_id, company_id, correlation_id, document_reference, finance_dpl_receipt_id, gross_total,
    idempotency_key, invoice_date, invoice_fingerprint, invoice_number, issued_by, issued_role, order_id,
    proforma_invoice_id, reason, status, tax_total, taxable_total
  ) values (
    v_inv, gen_random_uuid(), p_company, v_corr, 'DOC-' || v_corr, gen_random_uuid(), 100,
    'inv-' || v_corr, (now() at time zone 'Asia/Kolkata')::date - p_age, repeat('a', 64), 'INV-' || v_corr,
    gen_random_uuid(), 'FINANCE_HEAD', v_order, gen_random_uuid(), 'bridge fixture', 'ISSUED', 0, 100
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

create function bridge_t.mk_return(p_order uuid, p_customer uuid) returns uuid
language plpgsql as $$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.b2b_return_arrival_cases (id, case_number, order_id, customer_id, cartons_presented, external_condition, correlation_id)
  values (v_id, 'RC-' || substr(v_id::text, 1, 8), p_order, p_customer, 2, 'intact', 'rc-' || v_id::text);
  return v_id;
end $$;

-- Default privileges may revoke PUBLIC execute; the live sections call these helpers as authenticated/anon.
grant execute on all functions in schema bridge_t to public;

-- ---------------------------------------------------------------------------------------------------------------
-- 1. Catalogue / privilege contract
-- ---------------------------------------------------------------------------------------------------------------
select has_table('public', 'support_commercial_complaint_links', 'support link table exists');
select has_table('public', 'commercial_complaint_return_links', 'return link table exists');
select has_function('public', 'submit_customer_commercial_complaint_v1',
  array['text', 'uuid', 'text', 'text', 'jsonb', 'text', 'integer'], 'bridge intake RPC exists with the contracted signature');
select has_function('public', 'link_return_case_to_commercial_complaint_v1', array['uuid', 'uuid'], 'return link command exists');
select has_function('public', 'get_commercial_complaint_handoff_facts_v1', array['uuid'], 'handoff facts RPC exists');

select ok(
  (select count(*) = 4 from pg_attribute
    where attrelid = 'public.support_commercial_complaint_links'::regclass and attnum > 0 and not attisdropped)
  and (select count(*) = 4 from pg_attribute
    where attrelid = 'public.commercial_complaint_return_links'::regclass and attnum > 0 and not attisdropped),
  'both link tables carry exactly the four contracted columns'
);

select ok(
  not has_table_privilege('authenticated', 'public.support_commercial_complaint_links', 'INSERT')
  and not has_table_privilege('authenticated', 'public.support_commercial_complaint_links', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.support_commercial_complaint_links', 'DELETE')
  and not has_table_privilege('authenticated', 'public.support_commercial_complaint_links', 'TRUNCATE')
  and not has_table_privilege('service_role', 'public.support_commercial_complaint_links', 'INSERT')
  and not has_table_privilege('anon', 'public.support_commercial_complaint_links', 'SELECT')
  and has_table_privilege('authenticated', 'public.support_commercial_complaint_links', 'SELECT'),
  'support links: direct writes revoked from every API role, read via RLS only'
);
select ok(
  not has_table_privilege('authenticated', 'public.commercial_complaint_return_links', 'INSERT')
  and not has_table_privilege('authenticated', 'public.commercial_complaint_return_links', 'UPDATE')
  and not has_table_privilege('authenticated', 'public.commercial_complaint_return_links', 'DELETE')
  and not has_table_privilege('service_role', 'public.commercial_complaint_return_links', 'INSERT')
  and not has_table_privilege('anon', 'public.commercial_complaint_return_links', 'SELECT'),
  'return links: direct writes revoked from every API role'
);
select ok(
  (select relrowsecurity from pg_class where oid = 'public.support_commercial_complaint_links'::regclass)
  and (select relrowsecurity from pg_class where oid = 'public.commercial_complaint_return_links'::regclass),
  'RLS is enabled on both link tables'
);

select ok(
  has_function_privilege('authenticated', 'public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.link_return_case_to_commercial_complaint_v1(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.link_return_case_to_commercial_complaint_v1(uuid,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.link_return_case_to_commercial_complaint_v1(uuid,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.get_commercial_complaint_handoff_facts_v1(uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.get_commercial_complaint_handoff_facts_v1(uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.get_commercial_complaint_handoff_facts_v1(uuid)', 'EXECUTE'),
  'new RPCs are authenticated-only: no anon and no service_role execute'
);

-- Deployed authorities keep their signatures and caller scope (this migration must not alter them).
select ok(
  to_regprocedure('public.submit_customer_support_ticket_v2(text,uuid,text,text,text,integer)') is not null
  and has_function_privilege('authenticated', 'public.submit_customer_support_ticket_v2(text,uuid,text,text,text,integer)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.submit_customer_support_ticket_v2(text,uuid,text,text,text,integer)', 'EXECUTE'),
  'submit_customer_support_ticket_v2 signature and grants are unchanged'
);
select ok(
  has_function_privilege('authenticated', 'public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.file_commercial_complaint_v1(uuid,text,text,jsonb,text,text,text,uuid)', 'EXECUTE')
  and has_function_privilege('authenticated', 'public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('anon', 'public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)', 'EXECUTE')
  and not has_function_privilege('service_role', 'public.resolve_commercial_complaint_v1(uuid,text,numeric,text,text,text,text,text,text,uuid)', 'EXECUTE'),
  'file_commercial_complaint_v1 and resolve_commercial_complaint_v1 signatures and grants are unchanged'
);

select ok(
  pg_get_functiondef('public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)'::regprocedure) like '%pg_advisory_xact_lock%'
  and pg_get_functiondef('public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)'::regprocedure) like '%''support-ticket:'' || v_ticket_id::text%'
  and pg_get_functiondef('public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)'::regprocedure) like '%file_commercial_complaint_v1%'
  and pg_get_functiondef('public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)'::regprocedure) like '%submit_customer_support_ticket_v2%',
  'intake serialises retries, derives the complaint key server-side, and composes the two canonical authorities'
);
select ok(
  position('support_commercial_complaint_links' in pg_get_functiondef('public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)'::regprocedure))
    < position('file_commercial_complaint_v1' in pg_get_functiondef('public.submit_customer_commercial_complaint_v1(text,uuid,text,text,jsonb,text,integer)'::regprocedure)),
  'the immutable link / idempotency lookup precedes the canonical filing call (so it precedes any window test)'
);

-- ---------------------------------------------------------------------------------------------------------------
-- 2. Safe text order id cast
-- ---------------------------------------------------------------------------------------------------------------
select is(public.support_ticket_order_uuid_v1('LEGACY-ORDER-77'), null::uuid, 'legacy non-UUID order text yields NULL, never an error');
select ok(
  public.support_ticket_order_uuid_v1('  ') is null
  and public.support_ticket_order_uuid_v1(null) is null
  and public.support_ticket_order_uuid_v1('12345678-1234-1234-1234-12345678901') is null
  and public.support_ticket_order_uuid_v1('12345678123412341234123456789012') is null
  and public.support_ticket_order_uuid_v1('1234567g-1234-1234-1234-123456789012') is null,
  'blank, null, short, unhyphenated and non-hex text all yield NULL'
);
select is(
  public.support_ticket_order_uuid_v1('ABCDEF12-1234-4234-8234-ABCDEF123456'),
  'abcdef12-1234-4234-8234-abcdef123456'::uuid,
  'full canonical hyphenated hex (any case) casts to the uuid'
);

-- ---------------------------------------------------------------------------------------------------------------
-- 3. Fixtures
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_co_a uuid; v_co_b uuid;
begin
  set local session_replication_role = replica;

  insert into public.companies (business_name, status) values ('Bridge Co A', 'active') returning id into v_co_a;
  insert into public.companies (business_name, status) values ('Bridge Co B', 'active') returning id into v_co_b;
  perform set_config('bridge.co_a', v_co_a::text, true);
  perform set_config('bridge.co_b', v_co_b::text, true);

  perform set_config('bridge.buyer_a', gen_random_uuid()::text, true);
  perform set_config('bridge.buyer_b', gen_random_uuid()::text, true);
  perform set_config('bridge.buyer_unapproved', gen_random_uuid()::text, true);
  perform set_config('bridge.support', gen_random_uuid()::text, true);
  perform set_config('bridge.finance', gen_random_uuid()::text, true);
  perform set_config('bridge.sales', gen_random_uuid()::text, true);

  insert into auth.users (id, email) values
    (bridge_t.gv('buyer_a'), 'bridge-buyer-a@example.invalid'),
    (bridge_t.gv('buyer_b'), 'bridge-buyer-b@example.invalid'),
    (bridge_t.gv('buyer_unapproved'), 'bridge-buyer-u@example.invalid'),
    (bridge_t.gv('support'), 'bridge-support@example.invalid'),
    (bridge_t.gv('finance'), 'bridge-finance@example.invalid'),
    (bridge_t.gv('sales'), 'bridge-sales@example.invalid');
  insert into public.profiles (id, company_id, role, is_approved, status, email) values
    (bridge_t.gv('buyer_a'), v_co_a, 'b2b_buyer', true, 'approved', 'bridge-buyer-a@example.invalid'),
    (bridge_t.gv('buyer_b'), v_co_b, 'b2b_buyer', true, 'approved', 'bridge-buyer-b@example.invalid'),
    (bridge_t.gv('buyer_unapproved'), v_co_a, 'b2b_buyer', false, 'pending', 'bridge-buyer-u@example.invalid');
  insert into public.users (id, email, role, is_active) values
    (bridge_t.gv('support'), 'bridge-support@example.invalid', 'support_executive', true),
    (bridge_t.gv('finance'), 'bridge-finance@example.invalid', 'finance_exec', true),
    (bridge_t.gv('sales'), 'bridge-sales@example.invalid', 'sales_executive', true);

  -- o_a1: open window (invoice today). o_a2: window already expired. o_a3: open window. o_a4: open window.
  perform set_config('bridge.o_a1', bridge_t.mk_order(v_co_a, 0)::text, true);
  perform set_config('bridge.o_a2', bridge_t.mk_order(v_co_a, 11)::text, true);
  perform set_config('bridge.o_a3', bridge_t.mk_order(v_co_a, 0)::text, true);
  perform set_config('bridge.o_a4', bridge_t.mk_order(v_co_a, 0)::text, true);
  perform set_config('bridge.o_b1', bridge_t.mk_order(v_co_b, 0)::text, true);

  -- Return cases. Company lineage comes from the owning order, never from customer_id: rc_ok deliberately carries an
  -- auth-user id (NOT a company id) as customer_id and must still link; unbound legacy means no order.
  perform set_config('bridge.rc_ok', bridge_t.mk_return(bridge_t.gv('o_a1'), bridge_t.gv('buyer_a'))::text, true);
  perform set_config('bridge.rc_wrong_order', bridge_t.mk_return(bridge_t.gv('o_a3'), v_co_a)::text, true);
  perform set_config('bridge.rc_other_company', bridge_t.mk_return(bridge_t.gv('o_b1'), v_co_b)::text, true);
  perform set_config('bridge.rc_legacy', bridge_t.mk_return(null, null)::text, true);
  perform set_config('bridge.rc_customer_only', bridge_t.mk_return(null, v_co_a)::text, true);

  set local session_replication_role = default;
end $$;
select pass('fixtures built: two companies, buyers, staff, five orders with ISSUED invoices, five return cases');

-- ---------------------------------------------------------------------------------------------------------------
-- 4. Pre-cutoff create, replay, then post-cutoff retry vs new rejection (+ rollback)
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_row record;
  v_replay record;
  v_ticket public.support_tickets%rowtype;
  v_complaint public.commercial_complaints%rowtype;
  v_link public.support_commercial_complaint_links%rowtype;
  v_expected_deadline timestamptz;
begin
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;

  execute bridge_t.call_sql('k-create-1', bridge_t.gv('o_a1'), 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 3) into v_row;
  perform set_config('bridge.t_a', v_row.ticket_id::text, true);
  perform set_config('bridge.c_a', v_row.complaint_id::text, true);
  if v_row.already_filed then raise exception 'first filing reported already_filed'; end if;
  if v_row.complaint_deadline is null or v_row.complaint_deadline <= statement_timestamp() then
    raise exception 'pre-cutoff filing must carry a future deadline, got %', v_row.complaint_deadline;
  end if;
  v_expected_deadline := public.complaint_deadline_from_invoice_v1((now() at time zone 'Asia/Kolkata')::date);
  if v_row.complaint_deadline is distinct from v_expected_deadline then
    raise exception 'deadline must be the canonical invoice-date deadline: % vs %', v_row.complaint_deadline, v_expected_deadline;
  end if;

  reset role;
  select * into v_ticket from public.support_tickets where id = v_row.ticket_id;
  select * into v_complaint from public.commercial_complaints where id = v_row.complaint_id;
  select * into v_link from public.support_commercial_complaint_links where support_ticket_id = v_row.ticket_id;
  if v_ticket.company_id is distinct from bridge_t.gv('co_a') or v_ticket.created_by is distinct from bridge_t.gv('buyer_a')
     or v_ticket.order_id is distinct from bridge_t.gv('o_a1')::text or v_ticket.idempotency_key is distinct from 'k-create-1'
     or v_ticket.issue_type is distinct from 'damage' or v_ticket.product_sku is distinct from 'SKU-7' or v_ticket.qty_affected is distinct from 3 then
    raise exception 'ticket not created from the server-derived buyer context: %', row_to_json(v_ticket);
  end if;
  if v_complaint.idempotency_key is distinct from 'support-ticket:' || v_row.ticket_id::text
     or v_complaint.correlation_id is distinct from 'support-ticket:' || v_row.ticket_id::text
     or v_complaint.complaint_type is distinct from 'DAMAGE' or v_complaint.company_id is distinct from bridge_t.gv('co_a')
     or v_complaint.order_id is distinct from bridge_t.gv('o_a1') or v_complaint.filed_by is distinct from bridge_t.gv('buyer_a')
     or v_complaint.evidence_references is distinct from '["photo-1.jpg","photo-2.jpg"]'::jsonb then
    raise exception 'complaint not filed through the canonical authority with the server-derived key: %', row_to_json(v_complaint);
  end if;
  if v_link.complaint_id is distinct from v_row.complaint_id or v_link.linked_by is distinct from bridge_t.gv('buyer_a') then
    raise exception 'link row wrong: %', row_to_json(v_link);
  end if;
  if (select count(*) from public.commercial_complaint_events where complaint_id = v_row.complaint_id and status = 'OPEN') <> 1 then
    raise exception 'canonical OPEN event missing';
  end if;
end $$;
select pass('pre-cutoff create: ticket, canonical complaint (server-derived key) and immutable link written together');

do $$
declare v_row record; v_again record;
begin
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  execute bridge_t.call_sql('k-create-1', bridge_t.gv('o_a1'), 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 3) into v_again;
  reset role;
  if not v_again.already_filed or v_again.ticket_id is distinct from bridge_t.gv('t_a') or v_again.complaint_id is distinct from bridge_t.gv('c_a') then
    raise exception 'same-payload retry must return the original ticket and complaint with already_filed=true: %', row_to_json(v_again);
  end if;
  if (select count(*) from public.support_tickets where idempotency_key = 'k-create-1') <> 1
     or (select count(*) from public.commercial_complaints where order_id = bridge_t.gv('o_a1')) <> 1
     or (select count(*) from public.support_commercial_complaint_links where support_ticket_id = bridge_t.gv('t_a')) <> 1 then
    raise exception 'retry created duplicate rows';
  end if;
end $$;
select pass('same-key same-payload retry is idempotent (no duplicate ticket, complaint or link)');

do $$
declare
  v_again record;
  v_tickets bigint; v_complaints bigint; v_links bigint; v_events bigint;
begin
  -- The window closes: the order's final invoice is now 11 IST days old.
  set local session_replication_role = replica;
  update public.final_invoices set invoice_date = (now() at time zone 'Asia/Kolkata')::date - 11 where order_id = bridge_t.gv('o_a1');
  set local session_replication_role = default;

  select count(*) into v_tickets from public.support_tickets;
  select count(*) into v_complaints from public.commercial_complaints;
  select count(*) into v_links from public.support_commercial_complaint_links;
  select count(*) into v_events from public.commercial_complaint_events;

  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;

  -- Post-cutoff retry of an already-filed complaint: the immutable link is honoured BEFORE the window test.
  execute bridge_t.call_sql('k-create-1', bridge_t.gv('o_a1'), 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 3) into v_again;
  if not v_again.already_filed or v_again.complaint_id is distinct from bridge_t.gv('c_a') then
    raise exception 'post-cutoff idempotent retry must return the original result: %', row_to_json(v_again);
  end if;

  -- A NEW filing after the cutoff is rejected, and the whole call rolls back (ticket included).
  perform bridge_t.expect_error(
    bridge_t.call_sql('k-late-1', bridge_t.gv('o_a1'), 'SHORTAGE', 'Two cartons short against the invoice',
      '["short-1.jpg"]'::jsonb),
    '55000', 'COMPLAINT_WINDOW_EXPIRED');
  reset role;

  if (select count(*) from public.support_tickets) <> v_tickets
     or (select count(*) from public.commercial_complaints) <> v_complaints
     or (select count(*) from public.support_commercial_complaint_links) <> v_links
     or (select count(*) from public.commercial_complaint_events) <> v_events
     or exists (select 1 from public.support_tickets where idempotency_key = 'k-late-1') then
    raise exception 'post-cutoff rejection left partial state behind';
  end if;
end $$;
select pass('post-cutoff: idempotent retry returns the original; a new filing is rejected and fully rolled back');

-- ---------------------------------------------------------------------------------------------------------------
-- 5. Conflicting payloads on an existing key
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_o1 uuid := bridge_t.gv('o_a1');
  v_o3 uuid := bridge_t.gv('o_a3');
begin
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  perform bridge_t.expect_error(bridge_t.call_sql('k-create-1', v_o1, 'DAMAGE', 'A different description entirely here',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 3), 'P0001', 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT');
  perform bridge_t.expect_error(bridge_t.call_sql('k-create-1', v_o1, 'SHORTAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 3), 'P0001', 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT');
  perform bridge_t.expect_error(bridge_t.call_sql('k-create-1', v_o1, 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["other-photo.jpg"]'::jsonb, 'SKU-7', 3), 'P0001', 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT');
  perform bridge_t.expect_error(bridge_t.call_sql('k-create-1', v_o1, 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 4), 'P0001', 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT');
  perform bridge_t.expect_error(bridge_t.call_sql('k-create-1', v_o1, 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-8', 3), 'P0001', 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT');
  perform bridge_t.expect_error(bridge_t.call_sql('k-create-1', v_o3, 'DAMAGE', 'Cartons crushed on arrival at dock',
    '["photo-1.jpg","photo-2.jpg"]'::jsonb, 'SKU-7', 3), 'P0001', 'COMPLAINT_BRIDGE_IDEMPOTENCY_CONFLICT');
  reset role;
  if (select count(*) from public.commercial_complaints) <> 1 then raise exception 'conflicting replays must not create complaints'; end if;
end $$;
select pass('conflicting replay (description, type, evidence, quantity, SKU, order) is rejected without side effects');

-- ---------------------------------------------------------------------------------------------------------------
-- 6. Invalid type / evidence / actor / company / input
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_o3 uuid := bridge_t.gv('o_a3');
  v_ev jsonb := '["ok.jpg"]'::jsonb;
  v_d text := 'Valid description over ten chars';
  v_before bigint;
begin
  select count(*) into v_before from public.support_tickets;
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;

  -- Type must be an explicit canonical value; Other / free text / case variants / blank / NULL are rejected.
  perform bridge_t.expect_error(bridge_t.call_sql('k-t1', v_o3, 'Other', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_TYPE_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('k-t2', v_o3, 'OTHER', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_TYPE_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('k-t3', v_o3, 'damage', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_TYPE_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('k-t4', v_o3, 'QUALITY', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_TYPE_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('k-t5', v_o3, '', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_TYPE_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('k-t6', v_o3, null, v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_TYPE_INVALID');

  -- Evidence must be a non-empty array of non-blank references.
  perform bridge_t.expect_error(bridge_t.call_sql('k-e1', v_o3, 'DAMAGE', v_d, '[]'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e2', v_o3, 'DAMAGE', v_d, '{}'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e3', v_o3, 'DAMAGE', v_d, '"photo.jpg"'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e4', v_o3, 'DAMAGE', v_d, '[""]'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e5', v_o3, 'DAMAGE', v_d, '["   "]'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e6', v_o3, 'DAMAGE', v_d, '[{}]'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e7', v_o3, 'DAMAGE', v_d, '[1]'::jsonb), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql('k-e8', v_o3, 'DAMAGE', v_d, null), '22023', 'COMPLAINT_BRIDGE_EVIDENCE_REQUIRED');

  -- Other input guards.
  perform bridge_t.expect_error(bridge_t.call_sql('k-d1', v_o3, 'DAMAGE', 'short', v_ev), '22023', 'COMPLAINT_BRIDGE_DESCRIPTION_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('k-q1', v_o3, 'DAMAGE', v_d, v_ev, null, 0), '22023', 'COMPLAINT_BRIDGE_QUANTITY_INVALID');
  perform bridge_t.expect_error(bridge_t.call_sql('   ', v_o3, 'DAMAGE', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_IDEMPOTENCY_KEY_REQUIRED');
  perform bridge_t.expect_error(bridge_t.call_sql(null, v_o3, 'DAMAGE', v_d, v_ev), '22023', 'COMPLAINT_BRIDGE_IDEMPOTENCY_KEY_REQUIRED');

  -- Company binding: a random order and another company's order are both unavailable to buyer A.
  perform bridge_t.expect_error(bridge_t.call_sql('k-o1', gen_random_uuid(), 'DAMAGE', v_d, v_ev), '42501', 'COMPLAINT_BRIDGE_ORDER_NOT_AVAILABLE');
  perform bridge_t.expect_error(bridge_t.call_sql('k-o2', bridge_t.gv('o_b1'), 'DAMAGE', v_d, v_ev), '42501', 'COMPLAINT_BRIDGE_ORDER_NOT_AVAILABLE');

  -- Buyer B cannot file against company A's order.
  perform bridge_t.claims(bridge_t.gv('buyer_b'));
  perform bridge_t.expect_error(bridge_t.call_sql('k-o3', v_o3, 'DAMAGE', v_d, v_ev), '42501', 'COMPLAINT_BRIDGE_ORDER_NOT_AVAILABLE');

  -- Actor: unapproved buyer, internal staff, and an unauthenticated authenticated-role call are all rejected.
  perform bridge_t.claims(bridge_t.gv('buyer_unapproved'));
  perform bridge_t.expect_error(bridge_t.call_sql('k-a1', v_o3, 'DAMAGE', v_d, v_ev), '42501', 'COMPLAINT_BRIDGE_BUYER_CONTEXT_REQUIRED');
  perform bridge_t.claims(bridge_t.gv('support'));
  perform bridge_t.expect_error(bridge_t.call_sql('k-a2', v_o3, 'DAMAGE', v_d, v_ev), '42501', 'COMPLAINT_BRIDGE_BUYER_CONTEXT_REQUIRED');
  perform set_config('request.jwt.claims', json_build_object('role', 'authenticated')::text, true);
  perform bridge_t.expect_error(bridge_t.call_sql('k-a3', v_o3, 'DAMAGE', v_d, v_ev), '28000', 'AUTH_REQUIRED%');
  set local role anon;
  perform bridge_t.expect_error(bridge_t.call_sql('k-a4', v_o3, 'DAMAGE', v_d, v_ev), '42501', 'permission denied%');
  reset role;

  if (select count(*) from public.support_tickets) <> v_before then
    raise exception 'a rejected call created a ticket';
  end if;
end $$;
select pass('invalid type/evidence/input, cross-company order, and non-buyer actors are rejected with no side effects');

-- ---------------------------------------------------------------------------------------------------------------
-- 7. Legacy text order ids and historical (non-backdated) tickets
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_legacy uuid := gen_random_uuid();
begin
  set local session_replication_role = replica;
  insert into public.support_tickets (id, company_id, order_id, issue_type, description, status, created_by, user_id)
  values (v_legacy, bridge_t.gv('co_a'), 'LEGACY-ORDER-77', 'damage', 'Legacy text-order ticket predating UUID ids', 'open',
          bridge_t.gv('buyer_a'), bridge_t.gv('buyer_a'));
  set local session_replication_role = default;
  perform set_config('bridge.t_legacy', v_legacy::text, true);

  -- A link between a legacy-text-order ticket and a real complaint is a lineage mismatch (guarded cast, no 22P02).
  perform bridge_t.expect_error(
    format('insert into public.support_commercial_complaint_links (support_ticket_id, complaint_id, linked_by) values (%L, %L, %L)',
      v_legacy, bridge_t.gv('c_a'), bridge_t.gv('buyer_a')),
    'P0001', 'SUPPORT_COMPLAINT_LINK_LINEAGE_MISMATCH');
end $$;
select pass('legacy text order_id is guarded: link attempt fails with a lineage error, never an invalid-uuid cast error');

do $$
declare
  v_t3 uuid; v_row record; v_ticket_created timestamptz; v_c public.commercial_complaints%rowtype;
  v_l public.support_commercial_complaint_links%rowtype; v_t2 uuid; v_before bigint;
begin
  -- (a) A genuinely historical, unlinked ticket on an order whose window is still open is reconciled by the bridge:
  --     the complaint and link are stamped NOW; nothing is backdated to the ticket's age.
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  select t.ticket_id into v_t3 from public.submit_customer_support_ticket_v2(
    'k-hist-1', bridge_t.gv('o_a3'), 'shortage', 'Historic shortage ticket raised weeks ago', null, null) as t;
  reset role;
  set local session_replication_role = replica;
  update public.support_tickets set created_at = now() - interval '20 days' where id = v_t3;
  set local session_replication_role = default;
  select created_at into v_ticket_created from public.support_tickets where id = v_t3;

  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  execute bridge_t.call_sql('k-hist-1', bridge_t.gv('o_a3'), 'SHORTAGE', 'Historic shortage ticket raised weeks ago',
    '["hist.jpg"]'::jsonb) into v_row;
  reset role;
  if v_row.ticket_id is distinct from v_t3 or v_row.already_filed then
    raise exception 'historical ticket must be reconciled, not duplicated: %', row_to_json(v_row);
  end if;
  select * into v_c from public.commercial_complaints where id = v_row.complaint_id;
  select * into v_l from public.support_commercial_complaint_links where support_ticket_id = v_t3;
  if v_c.filed_at < v_ticket_created + interval '19 days' or v_l.linked_at < v_ticket_created + interval '19 days' then
    raise exception 'complaint/link were backdated to the historical ticket: filed % linked % ticket %', v_c.filed_at, v_l.linked_at, v_ticket_created;
  end if;
  if v_c.complaint_deadline is distinct from public.complaint_deadline_from_invoice_v1((now() at time zone 'Asia/Kolkata')::date) then
    raise exception 'ticket age must not move the invoice-date deadline';
  end if;
  perform set_config('bridge.t_hist', v_t3::text, true);
  perform set_config('bridge.c_hist', v_row.complaint_id::text, true);

  -- (b) A historical unlinked ticket on an order whose window is closed cannot be turned into a complaint.
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  select t.ticket_id into v_t2 from public.submit_customer_support_ticket_v2(
    'k-hist-2', bridge_t.gv('o_a2'), 'damage', 'Historic damage ticket on an expired window', null, null) as t;
  reset role;
  set local session_replication_role = replica;
  update public.support_tickets set created_at = now() - interval '20 days' where id = v_t2;
  set local session_replication_role = default;
  select count(*) into v_before from public.commercial_complaints;

  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  perform bridge_t.expect_error(bridge_t.call_sql('k-hist-2', bridge_t.gv('o_a2'), 'DAMAGE',
    'Historic damage ticket on an expired window', '["hist2.jpg"]'::jsonb), '55000', 'COMPLAINT_WINDOW_EXPIRED');
  reset role;
  if (select count(*) from public.commercial_complaints) <> v_before
     or exists (select 1 from public.support_commercial_complaint_links where support_ticket_id = v_t2)
     or not exists (select 1 from public.support_tickets where id = v_t2) then
    raise exception 'expired historical ticket must stay unlinked and untouched';
  end if;
end $$;
select pass('historical tickets are never backdated: open window reconciles at now(); expired window is rejected and stays unlinked');

-- ---------------------------------------------------------------------------------------------------------------
-- 8. Link failure rolls the whole intake back
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_tickets bigint; v_complaints bigint; v_events bigint;
begin
  create function bridge_t.fail_link() returns trigger language plpgsql as $f$
  begin raise exception 'TEST_LINK_FAILURE' using errcode = 'P0001'; end $f$;
  create trigger trg_bridge_t_fail_link before insert on public.support_commercial_complaint_links
    for each row execute function bridge_t.fail_link();

  select count(*) into v_tickets from public.support_tickets;
  select count(*) into v_complaints from public.commercial_complaints;
  select count(*) into v_events from public.commercial_complaint_events;

  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  perform bridge_t.expect_error(bridge_t.call_sql('k-fail-1', bridge_t.gv('o_a4'), 'WRONG_PRODUCT', 'Received the wrong flavour of product',
    '["wrong.jpg"]'::jsonb), 'P0001', 'TEST_LINK_FAILURE');
  reset role;

  if (select count(*) from public.support_tickets) <> v_tickets
     or (select count(*) from public.commercial_complaints) <> v_complaints
     or (select count(*) from public.commercial_complaint_events) <> v_events
     or exists (select 1 from public.support_tickets where idempotency_key = 'k-fail-1') then
    raise exception 'link failure left a ticket, complaint or event behind';
  end if;
  drop trigger trg_bridge_t_fail_link on public.support_commercial_complaint_links;
end $$;
select pass('link insertion failure rolls back the ticket, the canonical complaint and its events (all-or-nothing)');

-- ---------------------------------------------------------------------------------------------------------------
-- 9. Append-only and direct-write protection; RLS reads
-- ---------------------------------------------------------------------------------------------------------------
do $$
begin
  -- Direct writes from API roles are denied outright.
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  perform bridge_t.expect_error(
    format('insert into public.support_commercial_complaint_links (support_ticket_id, complaint_id, linked_by) values (%L, %L, %L)',
      bridge_t.gv('t_legacy'), bridge_t.gv('c_a'), bridge_t.gv('buyer_a')), '42501', 'permission denied%');
  perform bridge_t.expect_error('update public.support_commercial_complaint_links set linked_by = linked_by', '42501', 'permission denied%');
  perform bridge_t.expect_error('delete from public.support_commercial_complaint_links', '42501', 'permission denied%');
  perform bridge_t.expect_error('truncate public.support_commercial_complaint_links', '42501', 'permission denied%');
  perform bridge_t.expect_error(
    format('insert into public.commercial_complaint_return_links (return_case_id, complaint_id, linked_by) values (%L, %L, %L)',
      bridge_t.gv('rc_ok'), bridge_t.gv('c_a'), bridge_t.gv('buyer_a')), '42501', 'permission denied%');
  reset role;

  -- Even the owner cannot rewrite history: UPDATE / DELETE / TRUNCATE are blocked by trigger.
  perform bridge_t.expect_error('update public.support_commercial_complaint_links set linked_by = linked_by', '42501', 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY');
  perform bridge_t.expect_error('delete from public.support_commercial_complaint_links', '42501', 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY');
  perform bridge_t.expect_error('truncate public.support_commercial_complaint_links', '42501', 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY');
end $$;
select pass('support links: direct API writes denied; owner-level UPDATE/DELETE/TRUNCATE blocked (append-only)');

do $$
declare v_n bigint;
begin
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  set local role authenticated;
  select count(*) into v_n from public.support_commercial_complaint_links;
  if v_n < 2 then raise exception 'buyer A must read own-company links, saw %', v_n; end if;
  if exists (select 1 from public.support_commercial_complaint_links where complaint_id not in (select id from public.commercial_complaints where company_id = bridge_t.gv('co_a'))) then
    raise exception 'buyer A saw a foreign link';
  end if;

  perform bridge_t.claims(bridge_t.gv('buyer_b'));
  select count(*) into v_n from public.support_commercial_complaint_links;
  if v_n <> 0 then raise exception 'buyer B must not see company A links, saw %', v_n; end if;

  perform bridge_t.claims(bridge_t.gv('support'));
  select count(*) into v_n from public.support_commercial_complaint_links;
  if v_n < 2 then raise exception 'support operator must read links, saw %', v_n; end if;

  perform bridge_t.claims(bridge_t.gv('finance'));
  select count(*) into v_n from public.support_commercial_complaint_links;
  if v_n < 2 then raise exception 'finance must read links, saw %', v_n; end if;

  perform bridge_t.claims(bridge_t.gv('sales'));
  select count(*) into v_n from public.support_commercial_complaint_links;
  if v_n <> 0 then raise exception 'unrelated staff must not read links, saw %', v_n; end if;

  set local role anon;
  perform bridge_t.expect_error('select count(*) from public.support_commercial_complaint_links', '42501', 'permission denied%');
  reset role;
end $$;
select pass('RLS: own-company buyer and Support/Finance read links; other buyers, unrelated staff and anon do not');

-- ---------------------------------------------------------------------------------------------------------------
-- 10. Return lineage command
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare
  v_case_before text; v_case_after text; v_row record; v_again record;
  v_adj bigint; v_items bigint; v_decisions bigint;
begin
  select md5(r::text) into v_case_before from public.b2b_return_arrival_cases r where r.id = bridge_t.gv('rc_ok');
  select count(*) into v_adj from public.commercial_adjustments;
  select count(*) into v_items from public.b2b_return_arrival_items;
  select count(*) into v_decisions from public.b2b_return_arrival_decisions;

  perform bridge_t.claims(bridge_t.gv('support'));
  set local role authenticated;
  select * into v_row from public.link_return_case_to_commercial_complaint_v1(bridge_t.gv('rc_ok'), bridge_t.gv('c_a'));
  if v_row.already_linked or v_row.return_case_id is distinct from bridge_t.gv('rc_ok') then
    raise exception 'first link must report already_linked=false: %', row_to_json(v_row);
  end if;
  select * into v_again from public.link_return_case_to_commercial_complaint_v1(bridge_t.gv('rc_ok'), bridge_t.gv('c_a'));
  if not v_again.already_linked then raise exception 'repeat link must be idempotent (already_linked=true)'; end if;

  -- Wrong order, other company, unbound legacy shapes, conflicting complaint.
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_wrong_order'), bridge_t.gv('c_a')), 'P0001', 'RETURN_COMPLAINT_LINEAGE_MISMATCH');
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_other_company'), bridge_t.gv('c_a')), 'P0001', 'RETURN_COMPLAINT_LINEAGE_MISMATCH');
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_legacy'), bridge_t.gv('c_a')), '55000', 'RETURN_CASE_UNBOUND_LEGACY');
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_customer_only'), bridge_t.gv('c_a')), '55000', 'RETURN_CASE_UNBOUND_LEGACY');
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_ok'), bridge_t.gv('c_hist')), 'P0001', 'RETURN_LINK_CONFLICT');
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    gen_random_uuid(), bridge_t.gv('c_a')), 'P0001', 'RETURN_CASE_NOT_FOUND');
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_ok'), gen_random_uuid()), 'P0001', 'RETURN_LINK_CONFLICT');
  perform bridge_t.expect_error('select * from public.link_return_case_to_commercial_complaint_v1(null, null)', '22023', 'RETURN_LINK_ARGUMENTS_REQUIRED');

  -- Actor gate: buyers and unrelated staff cannot link; anon cannot execute.
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_ok'), bridge_t.gv('c_a')), '42501', 'RETURN_LINK_ACTOR_NOT_AUTHORIZED');
  perform bridge_t.claims(bridge_t.gv('sales'));
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_ok'), bridge_t.gv('c_a')), '42501', 'RETURN_LINK_ACTOR_NOT_AUTHORIZED');
  set local role anon;
  perform bridge_t.expect_error(format('select * from public.link_return_case_to_commercial_complaint_v1(%L, %L)',
    bridge_t.gv('rc_ok'), bridge_t.gv('c_a')), '42501', 'permission denied%');
  reset role;

  -- Quarantine / QA / stock / liability / finance are untouched by linking.
  select md5(r::text) into v_case_after from public.b2b_return_arrival_cases r where r.id = bridge_t.gv('rc_ok');
  if v_case_after is distinct from v_case_before then raise exception 'linking modified the return case'; end if;
  if (select count(*) from public.commercial_adjustments) <> v_adj
     or (select count(*) from public.b2b_return_arrival_items) <> v_items
     or (select count(*) from public.b2b_return_arrival_decisions) <> v_decisions then
    raise exception 'linking touched adjustments, items or decisions';
  end if;
  if (select count(*) from public.commercial_complaint_return_links) <> 1 then
    raise exception 'rejected links must not persist';
  end if;
end $$;
select pass('return lineage: order/owning-company match links idempotently (customer_id never consulted); wrong order, other company, unbound legacy, conflict and non-staff are rejected; case state untouched');

do $$
begin
  -- Table-level backstop: even a direct superuser insert cannot create mismatched or unbound lineage.
  perform bridge_t.expect_error(
    format('insert into public.commercial_complaint_return_links (return_case_id, complaint_id, linked_by) values (%L, %L, %L)',
      bridge_t.gv('rc_legacy'), bridge_t.gv('c_a'), bridge_t.gv('support')), '55000', 'RETURN_CASE_UNBOUND_LEGACY');
  perform bridge_t.expect_error(
    format('insert into public.commercial_complaint_return_links (return_case_id, complaint_id, linked_by) values (%L, %L, %L)',
      bridge_t.gv('rc_other_company'), bridge_t.gv('c_a'), bridge_t.gv('support')), 'P0001', 'RETURN_COMPLAINT_LINEAGE_MISMATCH');
  perform bridge_t.expect_error('update public.commercial_complaint_return_links set linked_by = linked_by', '42501', 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY');
  perform bridge_t.expect_error('delete from public.commercial_complaint_return_links', '42501', 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY');
  perform bridge_t.expect_error('truncate public.commercial_complaint_return_links', '42501', 'COMPLAINT_BRIDGE_LINKS_APPEND_ONLY');
end $$;
select pass('return links: lineage trigger and append-only guards hold even for owner-level writes');

do $$
declare v_n bigint;
begin
  perform bridge_t.claims(bridge_t.gv('support'));
  set local role authenticated;
  select count(*) into v_n from public.commercial_complaint_return_links;
  if v_n <> 1 then raise exception 'support must read return links, saw %', v_n; end if;
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  select count(*) into v_n from public.commercial_complaint_return_links;
  if v_n <> 0 then raise exception 'buyers must not read return links, saw %', v_n; end if;
  reset role;
end $$;
select pass('return links are staff-readable only');

-- ---------------------------------------------------------------------------------------------------------------
-- 11. Handoff facts (before resolution), Finance AAL2-only resolution, handoff facts (after)
-- ---------------------------------------------------------------------------------------------------------------
do $$
declare v_row record; v_n bigint;
begin
  perform bridge_t.claims(bridge_t.gv('support'));
  set local role authenticated;
  select * into v_row from public.get_commercial_complaint_handoff_facts_v1(bridge_t.gv('t_a'));
  if not found or v_row.complaint_id is distinct from bridge_t.gv('c_a')
     or v_row.order_id is distinct from bridge_t.gv('o_a1') or v_row.company_id is distinct from bridge_t.gv('co_a')
     or v_row.complaint_type is distinct from 'DAMAGE' or v_row.complaint_status is distinct from 'OPEN'
     or v_row.return_case_ids is distinct from array[bridge_t.gv('rc_ok')]
     or v_row.adjustment_count is distinct from 0 or v_row.adjustments is distinct from '[]'::jsonb
     or v_row.resolved is distinct from false then
    raise exception 'pre-resolution handoff facts wrong: %', row_to_json(v_row);
  end if;

  perform bridge_t.claims(bridge_t.gv('finance'));
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(bridge_t.gv('t_a'));
  if v_n <> 1 then raise exception 'finance must read handoff facts'; end if;

  -- Buyers, unrelated staff, anon, legacy-text tickets and unlinked tickets get nothing (and never an error).
  perform bridge_t.claims(bridge_t.gv('buyer_a'));
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(bridge_t.gv('t_a'));
  if v_n <> 0 then raise exception 'buyers must not read handoff facts'; end if;
  perform bridge_t.claims(bridge_t.gv('sales'));
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(bridge_t.gv('t_a'));
  if v_n <> 0 then raise exception 'unrelated staff must not read handoff facts'; end if;
  perform bridge_t.claims(bridge_t.gv('support'));
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(bridge_t.gv('t_legacy'));
  if v_n <> 0 then raise exception 'legacy-text ticket has no bridge facts'; end if;
  select count(*) into v_n from public.get_commercial_complaint_handoff_facts_v1(gen_random_uuid());
  if v_n <> 0 then raise exception 'unknown ticket has no facts'; end if;
  set local role anon;
  perform bridge_t.expect_error(format('select * from public.get_commercial_complaint_handoff_facts_v1(%L)', bridge_t.gv('t_a')), '42501', 'permission denied%');
  reset role;
end $$;
select pass('handoff facts: scoped to Support/Finance; chain ticket -> link -> complaint -> return -> adjustments, OPEN before resolution');

do $$
declare v_res record; v_row record;
begin
  -- Resolution authority is unchanged: Finance AAL2 only.
  perform bridge_t.claims(bridge_t.gv('finance'), 'aal1');
  set local role authenticated;
  perform bridge_t.expect_error(
    format('select * from public.resolve_commercial_complaint_v1(%L, %L, 0, null, null, null, %L, %L, %L)',
      bridge_t.gv('c_a'), 'NO_FINANCIAL_ACTION', 'bridge test decision', 'corr-bridge-1', 'res-bridge-1'),
    '42501', 'FINANCE_CLEARANCE_AAL2_REQUIRED');

  perform bridge_t.claims(bridge_t.gv('support'), 'aal2');
  perform bridge_t.expect_error(
    format('select * from public.resolve_commercial_complaint_v1(%L, %L, 0, null, null, null, %L, %L, %L)',
      bridge_t.gv('c_a'), 'NO_FINANCIAL_ACTION', 'bridge test decision', 'corr-bridge-1', 'res-bridge-1'),
    'P0001', 'NOT_AUTHORIZED%');

  perform bridge_t.claims(bridge_t.gv('buyer_a'), 'aal2');
  perform bridge_t.expect_error(
    format('select * from public.resolve_commercial_complaint_v1(%L, %L, 0, null, null, null, %L, %L, %L)',
      bridge_t.gv('c_a'), 'NO_FINANCIAL_ACTION', 'bridge test decision', 'corr-bridge-1', 'res-bridge-1'),
    '42501', 'FINANCE_CLEARANCE_ACTOR_REQUIRED');

  perform bridge_t.claims(bridge_t.gv('finance'), 'aal2');
  if exists (select 1 from public.commercial_adjustments where complaint_id = bridge_t.gv('c_a')) then
    raise exception 'a rejected resolution persisted an adjustment';
  end if;

  perform bridge_t.claims(bridge_t.gv('finance'), 'aal2');
  select * into v_res from public.resolve_commercial_complaint_v1(
    bridge_t.gv('c_a'), 'NO_FINANCIAL_ACTION', 0, null, null, null, 'bridge test decision', 'corr-bridge-1', 'res-bridge-1');
  if v_res.already_resolved then raise exception 'first resolution reported already_resolved'; end if;

  perform bridge_t.claims(bridge_t.gv('support'));
  select * into v_row from public.get_commercial_complaint_handoff_facts_v1(bridge_t.gv('t_a'));
  if not found or v_row.resolved is distinct from true
     or v_row.complaint_status is distinct from 'RESOLVED'
     or v_row.adjustment_count is distinct from 1
     or (v_row.adjustments -> 0 ->> 'adjustment_type') is distinct from 'NO_FINANCIAL_ACTION' then
    raise exception 'post-resolution handoff facts wrong: %', row_to_json(v_row);
  end if;
  reset role;
end $$;
select pass('resolution stays Finance AAL2-only (aal1 Finance, Support and buyers rejected); handoff facts then show RESOLVED with the adjustment');

select * from finish();
rollback;
