-- Contract test for migration 20261027130000_wa450_d4_order_correction_ambiguity_gate (WA450-D4).
begin;
-- WA-100 / D4: order-interpretation safety. A customer's uncertain, conflicting or self-corrected
-- instruction must never become an autonomous commercial action; a clear correction must be applied.
-- Drives the real pipeline (stitch -> AI interpretation -> materialize -> autonomy -> draft).
select plan(44);

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'corea-admin@example.test');

insert into public.users (id, email, full_name, role) values
  ('a1000000-0000-0000-0000-000000000001', 'corea-admin@example.test', 'Core-A Admin', 'admin');

-- Knowledge Snapshot
insert into public.whatsapp_intelligence_knowledge_snapshots (
  id, schema_version, lifecycle, knowledge, content_checksum,
  created_by, reviewed_by, reviewed_at, approved_by, approved_at
) values (
  'a1000000-0000-0000-0000-000000000010',
  'wa-knowledge/v1', 'APPROVED',
  '{"terminology":{"pista special":"BAK-PIST-250"},"aliases":{"pista bites":"BAK-PIST-250"}}'::jsonb,
  '1111111111111111111111111111111111111111111111111111111111111111',
  'a1000000-0000-0000-0000-000000000001',
  'a1000000-0000-0000-0000-000000000001', statement_timestamp(),
  'a1000000-0000-0000-0000-000000000001', statement_timestamp()
);
select public.whatsapp_activate_intelligence_knowledge_snapshot('a1000000-0000-0000-0000-000000000010');

-- Products
insert into public.products (
  id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs, is_active, visible_in_catalog, is_catalogue_ready
) values
  ('a1000000-0000-0000-0000-000000000101', 'Pistachio Baklawa 250g', 'BAK-PIST-250', 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true),
  ('a1000000-0000-0000-0000-000000000102', 'Pistachio Baklawa 500g', 'BAK-PIST-500', 'Sweets', '1905', 'Box', '500g', 1, 1, true, true, true),
  ('a1000000-0000-0000-0000-000000000103', 'Cashew Pyramid 500g', 'CAS-PYR-500', 'Sweets', '1905', 'Box', '500g', 2, 2, true, true, true),
  ('a1000000-0000-0000-0000-000000000104', 'Special Assorted Mix', 'MIX-ASST-500', 'Sweets', '1905', 'Box', '500g', 1, 1, true, true, true),
  ('a1000000-0000-0000-0000-000000000105', 'Special Assorted Mix', 'MIX-ASST-1000', 'Sweets', '1905', 'Box', '1kg', 1, 1, true, true, true);

-- Governed Product Alias
insert into public.product_aliases (
  id, alias_text, canonical_name, product_id
) values (
  'a1000000-0000-0000-0000-000000000150', 'pistachio delight', 'Pistachio Baklawa 250g', 'a1000000-0000-0000-0000-000000000101'
);

-- Canonical B2B Pricing Rules
insert into public.product_pricing_rules (
  id, product_id, price_channel, price_type, base_price, calculated_price, uom, approval_status, valid_from
) values
  ('a1000000-0000-0000-0000-000000000161', 'a1000000-0000-0000-0000-000000000101', 'b2b', 'standard', 500.00, 500.00, 'Box', 'approved', current_date - 1),
  ('a1000000-0000-0000-0000-000000000162', 'a1000000-0000-0000-0000-000000000102', 'b2b', 'standard', 900.00, 900.00, 'Box', 'approved', current_date - 1),
  ('a1000000-0000-0000-0000-000000000163', 'a1000000-0000-0000-0000-000000000103', 'b2b', 'standard', 800.00, 800.00, 'Box', 'approved', current_date - 1),
  ('a1000000-0000-0000-0000-000000000164', 'a1000000-0000-0000-0000-000000000104', 'b2b', 'standard', 750.00, 750.00, 'Box', 'approved', current_date - 1),
  ('a1000000-0000-0000-0000-000000000165', 'a1000000-0000-0000-0000-000000000105', 'b2b', 'standard', 1400.00, 1400.00, 'Box', 'approved', current_date - 1);

-- Canonical B2B MOQ Rules
insert into public.product_moq_rules (
  id, product_id, channel, moq_applicable, moq_value, moq_uom, increment_value, increment_uom, min_carton_qty
) values
  ('a1000000-0000-0000-0000-000000000171', 'a1000000-0000-0000-0000-000000000101', 'b2b', true, 5, 'Box', 1, 'Box', null),
  ('a1000000-0000-0000-0000-000000000172', 'a1000000-0000-0000-0000-000000000102', 'b2b', true, 1, 'Box', 1, 'Box', null),
  ('a1000000-0000-0000-0000-000000000173', 'a1000000-0000-0000-0000-000000000103', 'b2b', true, 2, 'Box', 2, 'Box', 10),
  ('a1000000-0000-0000-0000-000000000174', 'a1000000-0000-0000-0000-000000000104', 'b2b', true, 1, 'Box', 1, 'Box', null),
  ('a1000000-0000-0000-0000-000000000175', 'a1000000-0000-0000-0000-000000000105', 'b2b', true, 1, 'Box', 1, 'Box', null);

-- Company 1: Clean Active Customer with 1 delivery branch
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'a1000000-0000-0000-0000-000000000201', 'Taj Sweets Bengaluru', '29ABCDE1234F1Z5', '919800000001', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values (
  'a1000000-0000-0000-0000-000000000211', 'a1000000-0000-0000-0000-000000000201',
  'Main Store', '100 MG Road', 'Bengaluru', 'Karnataka', '560001', true
);

-- Company 2: Customer with 2 delivery branches
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'a1000000-0000-0000-0000-000000000202', 'Oberoi Gourmet Foods', '29FGHIJ5678K2Z6', '919800000002', 'credit', 'active', false
);

insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode, is_default
) values
  ('a1000000-0000-0000-0000-000000000221', 'a1000000-0000-0000-0000-000000000202', 'Indiranagar Branch', '12 100ft Rd', 'Bengaluru', 'Karnataka', '560038', true),
  ('a1000000-0000-0000-0000-000000000222', 'a1000000-0000-0000-0000-000000000202', 'Koramangala Branch', '45 80ft Rd', 'Bengaluru', 'Karnataka', '560034', false);

-- Company 3: Frozen Customer
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values (
  'a1000000-0000-0000-0000-000000000203', 'Frozen Sweets Mart', '29KLMNO9012P3Z7', '919800000003', 'credit', 'active', true
);
insert into public.delivery_addresses (
  id, company_id, label, street_address, city, state, pincode
) values (
  'a1000000-0000-0000-0000-000000000231', 'a1000000-0000-0000-0000-000000000203',
  'Main', '10 Frozen Way', 'Bengaluru', 'Karnataka', '560001'
);

-- Company 4A and 4B: Shared Phone (Ambiguous Customer)
insert into public.companies (
  id, business_name, gst_number, phone, payment_terms, status, is_frozen
) values
  ('a1000000-0000-0000-0000-000000000204', 'Alpha Traders', '29AAAAA0000A1Z1', '919800000099', 'prepaid', 'active', false),
  ('a1000000-0000-0000-0000-000000000205', 'Beta Traders', '29BBBBB1111B2Z2', '919800000099', 'prepaid', 'active', false);

-- Switch to service_role context for RPC executions
select set_config('request.jwt.claims', json_build_object('role', 'service_role')::text, true);

-- Scenario driver: one bound sender, N inbound messages, one stitched packet, one AI interpretation.
-- Lines reference messages as "M1", "M2", ... which are rewritten to this scenario's provider ids.
create function pg_temp.d4_run(
  p_tag text, p_bodies text[], p_lines jsonb, p_corrections jsonb default null,
  p_intent text default 'ORDER'
) returns jsonb language plpgsql as $f$
declare
  v_phone text := '9199' || lpad((abs(hashtext(p_tag)) % 100000000)::text, 8, '0');
  v_contact uuid := gen_random_uuid();
  v_wm uuid[] := '{}';
  v_id uuid;
  v_n int;
  v_pmid text;
  v_packet uuid;
  v_interp uuid := gen_random_uuid();
  v_lines text := p_lines::text;
  v_conclusion jsonb;
  v_payload jsonb;
begin
  insert into public.whatsapp_contacts(id, phone_number, customer_name) values (v_contact, v_phone, 'D4 ' || p_tag);
  -- bind the sender to Taj Sweets (sender-bound identity, WA450-D3 compatible)
  insert into public.delivery_addresses(id, company_id, label, street_address, city, state, pincode, contact_phone, is_default)
  values (gen_random_uuid(), 'a1000000-0000-0000-0000-000000000201', 'D4 bind ' || p_tag, 'Aux', 'Bengaluru', 'Karnataka', '560001', v_phone, false);
  for v_n in 1 .. array_length(p_bodies, 1) loop
    v_pmid := 'prov-d4-' || p_tag || '-' || v_n;
    v_lines := replace(v_lines, '"M' || v_n || '"', '"' || v_pmid || '"');
    insert into public.whatsapp_inbound_messages(id, provider_message_id, sender_phone, message_body, message_type, received_at)
    values (gen_random_uuid(), v_pmid, v_phone, p_bodies[v_n], 'text', statement_timestamp());
    v_id := gen_random_uuid();
    insert into public.whatsapp_messages(id, contact_id, direction, message_type, content, provider, provider_message_id, status, message_timestamp, created_at)
    values (v_id, v_contact, 'inbound', 'text', p_bodies[v_n], 'click2api', v_pmid, 'received',
            statement_timestamp() + (v_n || ' seconds')::interval, statement_timestamp() + (v_n || ' seconds')::interval);
    v_wm := v_wm || v_id;
  end loop;
  perform public.stitch_whatsapp_messages_atomic(v_contact, v_wm, 300);
  select packet_id into v_packet from public.whatsapp_messages where id = v_wm[1];
  v_conclusion := jsonb_build_object(
    'intent', p_intent, 'summary', 'D4 ' || p_tag,
    'customer', jsonb_build_object('company_name', 'Taj Sweets Bengaluru', 'gst_number', '29ABCDE1234F1Z5'),
    'branch', jsonb_build_object('label', 'Main Store'),
    'order_lines', v_lines::jsonb);
  if p_corrections is not null then
    v_conclusion := v_conclusion || jsonb_build_object('corrections', replace(replace(p_corrections::text, '"M1"', '"prov-d4-' || p_tag || '-1"'), '"M2"', '"prov-d4-' || p_tag || '-2"')::jsonb);
  end if;
  insert into public.whatsapp_packet_ai_interpretations(
    id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version,
    knowledge_snapshot_id, knowledge_snapshot_schema_version, knowledge_snapshot_content_checksum,
    interpretation_schema_version, prompt_policy_version, resolver_policy_version
  ) values (
    v_interp, v_packet, 'fp-d4-' || p_tag,
    (select array_agg(provider_message_id order by message_timestamp) from public.whatsapp_messages where packet_id = v_packet and direction = 'inbound'),
    jsonb_build_object('confidence', 0.98, 'conclusion', v_conclusion),
    'test-model-v1', 'a1000000-0000-0000-0000-000000000010', 'wa-knowledge/v1',
    '1111111111111111111111111111111111111111111111111111111111111111',
    'wa-interpretation/v1', 'wa-prompt/v1', 'core-a-autonomy/v1');
  v_payload := public.whatsapp_materialize_packet_ai_case(v_packet, v_interp);
  return jsonb_build_object('packet_id', v_packet, 'interp_id', v_interp, 'payload', v_payload);
end $f$;

create function pg_temp.d4_drafts(p_packet uuid) returns int language sql as
  $$ select count(*)::int from public.sales_order_drafts where packet_id = p_packet $$;
create function pg_temp.d4_draft_qty(p_packet uuid) returns numeric language sql as
  $$ select coalesce(sum(coalesce(l.operator_quantity, l.normalized_quantity, l.raw_quantity)), 0)
       from public.sales_order_draft_lines l join public.sales_order_drafts d on d.id = l.draft_id where d.packet_id = p_packet $$;
create function pg_temp.d4_events(p_packet uuid, p_type text) returns int language sql as
  $$ select count(*)::int from public.whatsapp_case_events e join public.whatsapp_communication_cases c on c.id = e.case_id
      where c.packet_id = p_packet and e.event_type = p_type $$;
create temporary table d4 (tag text primary key, r jsonb);
grant all on d4 to public;

create function pg_temp.d4_reinterpret(p_packet uuid, p_tag text, p_lines jsonb) returns uuid language plpgsql as $f$
declare v_id uuid := gen_random_uuid();
begin
  insert into public.whatsapp_packet_ai_interpretations(
    id, packet_id, content_fingerprint, provider_message_ids, interpretation, model_version,
    knowledge_snapshot_id, knowledge_snapshot_schema_version, knowledge_snapshot_content_checksum,
    interpretation_schema_version, prompt_policy_version, resolver_policy_version)
  values (v_id, p_packet, 'fp-d4-' || p_tag,
    (select array_agg(provider_message_id order by message_timestamp) from public.whatsapp_messages where packet_id = p_packet and direction = 'inbound'),
    jsonb_build_object('confidence', 0.98, 'conclusion', jsonb_build_object('intent','ORDER','summary','D4 '||p_tag,
      'customer', jsonb_build_object('company_name','Taj Sweets Bengaluru','gst_number','29ABCDE1234F1Z5'),
      'branch', jsonb_build_object('label','Main Store'), 'order_lines', p_lines)),
    'test-model-v1','a1000000-0000-0000-0000-000000000010','wa-knowledge/v1',
    '1111111111111111111111111111111111111111111111111111111111111111',
    'wa-interpretation/v1','wa-prompt/v1','core-a-autonomy/v1');
  return v_id;
end $f$;

-- K1 control: a clear order is untouched
insert into d4 select 'k1', pg_temp.d4_run('k1', array['send 10 box BAK-PIST-250'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='k1'), 'AUTO_ELIGIBLE', 'K1 clear order: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='k1')), 10::numeric, 'K1 clear order: drafted quantity is 10');
-- C: Hinglish self-correction in one message  ('10 mix nahi 12 mix' = not 10, 12)
insert into d4 select 'c1', pg_temp.d4_run('c1', array['10 mix nahi 12 mix'], '[{"sku": "MIX-ASST-500", "product_name": "Special Assorted Mix", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb, '[{"provider_message_id": "M1", "supersedes": "10 mix", "replacement": "12 mix"}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='c1'), 'AUTO_ELIGIBLE', 'C1 corrected value 12 with the correction recorded: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='c1')), 12::numeric, 'C1 corrected value 12 with the correction recorded: drafted quantity is 12');
insert into d4 select 'c2', pg_temp.d4_run('c2', array['10 mix nahi 12 mix'], '[{"sku": "MIX-ASST-500", "product_name": "Special Assorted Mix", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb, '[{"provider_message_id": "M1", "supersedes": "10 mix", "replacement": "12 mix"}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='c2'), 'AUTO_ELIGIBLE', 'C2 model picked the NEGATED value 10: is NOT autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='c2')), 0, 'C2 model picked the NEGATED value 10: no draft or order is created');
select is(((select r->'payload'->>'human_decision_required' from d4 where tag='c2'))::boolean, true, 'C2: negated-value order is held for a human');
insert into d4 select 'c3', pg_temp.d4_run('c3', array['10 mix nahi 12 mix'], '[{"sku": "MIX-ASST-500", "product_name": "Special Assorted Mix", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}, {"sku": "MIX-ASST-500", "product_name": "Special Assorted Mix", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='c3'), 'AUTO_ELIGIBLE', 'C3 model listed both 10 and 12 as separate lines: is NOT autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='c3')), 0, 'C3 model listed both 10 and 12 as separate lines: no draft or order is created');
insert into d4 select 'c4', pg_temp.d4_run('c4', array['10 mix nahi 12 mix'], '[{"sku": "MIX-ASST-500", "product_name": "Special Assorted Mix", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='c4'), 'AUTO_ELIGIBLE', 'C4 the text itself negates 10, correction not separately recorded: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='c4')), 12::numeric, 'C4 the text itself negates 10, correction not separately recorded: drafted quantity is 12');
-- N: non-directional correction wording ('actually')
insert into d4 select 'n1', pg_temp.d4_run('n1', array['BAK-PIST-250 10 box, actually 12 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb, '[{"provider_message_id": "M1", "supersedes": "10 box", "replacement": "12 box"}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='n1'), 'AUTO_ELIGIBLE', 'N1 later value 12 with the correction recorded: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='n1')), 12::numeric, 'N1 later value 12 with the correction recorded: drafted quantity is 12');
insert into d4 select 'n2', pg_temp.d4_run('n2', array['BAK-PIST-250 10 box, actually 12 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='n2'), 'AUTO_ELIGIBLE', 'N2 correction wording but no recorded correction: is NOT autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='n2')), 0, 'N2 correction wording but no recorded correction: no draft or order is created');
insert into d4 select 'n3', pg_temp.d4_run('n3', array['BAK-PIST-250 10 box, actually 12 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb, '[{"provider_message_id": "M1", "supersedes": "10 box", "replacement": "12 box"}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='n3'), 'AUTO_ELIGIBLE', 'N3 model kept the superseded earlier value 10: is NOT autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='n3')), 0, 'N3 model kept the superseded earlier value 10: no draft or order is created');
-- X: correction arrives in a later message of the same packet
insert into d4 select 'x1', pg_temp.d4_run('x1', array['BAK-PIST-250 10 box','nahi 12 box karo'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1", "M2"]}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='x1'), 'AUTO_ELIGIBLE', 'X1 later message corrects to 12: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='x1')), 12::numeric, 'X1 later message corrects to 12: drafted quantity is 12');
insert into d4 select 'x2', pg_temp.d4_run('x2', array['BAK-PIST-250 10 box','nahi 12 box karo'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='x2'), 'AUTO_ELIGIBLE', 'X2 model cited only the first message and kept the superseded 10: is NOT autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='x2')), 0, 'X2 model cited only the first message and kept the superseded 10: no draft or order is created');
-- D: conflicting / duplicate lines
insert into d4 select 'd1', pg_temp.d4_run('d1', array['BAK-PIST-250 10 box aur BAK-PIST-250 15 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}, {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 15, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='d1'), 'AUTO_ELIGIBLE', 'D1 same SKU twice with different quantities: is NOT autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='d1')), 0, 'D1 same SKU twice with different quantities: no draft or order is created');
insert into d4 select 'd2', pg_temp.d4_run('d2', array['BAK-PIST-250 10 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}, {"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='d2'), 'AUTO_ELIGIBLE', 'D2 same SKU repeated is not autonomously approved');
-- R: replay
create temporary table d4_replay as select public.whatsapp_materialize_packet_ai_case((select (r->>'packet_id')::uuid from d4 where tag='c2'), (select (r->>'interp_id')::uuid from d4 where tag='c2')) as payload;
select isnt((select payload->>'autonomy_outcome' from d4_replay), 'AUTO_ELIGIBLE', 'R1 replay of the held order stays held');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='c2')), 0, 'R1 replay still creates no draft');
select is(pg_temp.d4_events((select (r->>'packet_id')::uuid from d4 where tag='c2'), 'ORDER_CORRECTION_AMBIGUITY_ROUTED'), 1, 'R1 the routing decision is recorded exactly once across replays');
create temporary table d4_replay2 as select public.whatsapp_materialize_packet_ai_case((select (r->>'packet_id')::uuid from d4 where tag='c1'), (select (r->>'interp_id')::uuid from d4 where tag='c1')) as payload;
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='c1')), 1, 'R2 replay of the approved correction keeps exactly one draft');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='c1')), 12::numeric, 'R2 replay keeps the corrected quantity');
-- F: working journeys must not be over-blocked
insert into d4 select 'f1', pg_temp.d4_run('f1', array['BAK-PIST-250 10 box, CAS-PYR-500 10 box, do not delay'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}, {"sku": "CAS-PYR-500", "product_name": "Cashew Pyramid 500g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='f1'), 'AUTO_ELIGIBLE', 'F1 two products and an unrelated negation: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='f1')), 20::numeric, 'F1 two products and an unrelated negation: drafted quantity is 20');
insert into d4 select 'f2', pg_temp.d4_run('f2', array['BAK-PIST-250 10 box, cash nahi UPI'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='f2'), 'AUTO_ELIGIBLE', 'F2 Hinglish negation unrelated to quantities: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='f2')), 10::numeric, 'F2 Hinglish negation unrelated to quantities: drafted quantity is 10');
insert into d4 select 'f3', pg_temp.d4_run('f3', array['BAK-PIST-250 12 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb, '[]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='f3'), 'AUTO_ELIGIBLE', 'F3 empty corrections array does not block');
-- E: English negation of the chosen number must not reconcile it ("not 12 box" negates 12)
insert into d4 select 'e1', pg_temp.d4_run('e1', array['send 10 box BAK-PIST-250, not 12 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 12, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select isnt((select r->'payload'->>'autonomy_outcome' from d4 where tag='e1'), 'AUTO_ELIGIBLE', 'E1 English "not 12 box" with the model choosing 12 is not autonomously approved');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='e1')), 0, 'E1 no draft or order is created');
-- Q: a non-numeric quantity must route to a human, never raise
insert into d4 select 'q1', pg_temp.d4_run('q1', array['BAK-PIST-250 ten box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": "ten", "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='q1')), 0, 'Q1 non-numeric model quantity does not raise and creates no draft');
-- S: lines with different quantities need an unambiguous product attribution
insert into d4 select 's1', pg_temp.d4_run('s1', array['BAK-PIST-250 10 box, CAS-PYR-500 20 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}, {"sku": "CAS-PYR-500", "product_name": "Cashew Pyramid 500g", "quantity": 20, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is((select r->'payload'->>'autonomy_outcome' from d4 where tag='s1'), 'AUTO_ELIGIBLE', 'S1 distinct quantities attributed next to their own product codes: reaches AUTO_ELIGIBLE');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='s1')), 30::numeric, 'S1 drafted quantity is 10 + 20');
insert into d4 select 's2', pg_temp.d4_run('s2', array['BAK-PIST-250 10 box, CAS-PYR-500 20 box'], '[{"sku": "BAK-PIST-250", "product_name": "Pistachio Baklawa 250g", "quantity": 20, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}, {"sku": "CAS-PYR-500", "product_name": "Cashew Pyramid 500g", "quantity": 10, "unit": "box", "status": "explicit", "evidence_ids": ["M1"]}]'::jsonb);
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='s2')), 0, 'S2 quantities swapped between two products: no draft or order is created');

-- P: a stale/conflicting interpretation after a draft exists must not change or duplicate it
create temporary table d4_p1 as
select pg_temp.d4_reinterpret((select (r->>'packet_id')::uuid from d4 where tag='c1'), 'p1',
  '[{"sku":"MIX-ASST-500","product_name":"Special Assorted Mix","quantity":10,"unit":"box","status":"explicit","evidence_ids":["prov-d4-c1-1"]}]'::jsonb) as interp_id;
create temporary table d4_p1r as
select public.whatsapp_materialize_packet_ai_case((select (r->>'packet_id')::uuid from d4 where tag='c1'), (select interp_id from d4_p1)) as payload;
select isnt((select payload->>'autonomy_outcome' from d4_p1r), 'AUTO_ELIGIBLE',
  'P1 a stale conflicting interpretation after conversion is not autonomously applied (routed to a human)');
select is(pg_temp.d4_events((select (r->>'packet_id')::uuid from d4 where tag='c1'), 'ORDER_CORRECTION_AMBIGUITY_ROUTED'), 1,
  'P1 the stale interpretation is recorded as a routed ambiguity');
select is(pg_temp.d4_drafts((select (r->>'packet_id')::uuid from d4 where tag='c1')), 1, 'P1 no second draft is created');
select is(pg_temp.d4_draft_qty((select (r->>'packet_id')::uuid from d4 where tag='c1')), 12::numeric, 'P1 the drafted quantity is not silently changed');

select * from finish();
rollback;
