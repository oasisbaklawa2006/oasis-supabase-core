import { execFileSync } from 'node:child_process';
import { mkdirSync, writeFileSync } from 'node:fs';
import { randomBytes, randomUUID } from 'node:crypto';

const projectRef = process.env.EXPECTED_PROJECT_REF;
const url = process.env.SUPABASE_URL?.replace(/\/$/, '');
const publishableKey = process.env.SUPABASE_PUBLISHABLE_KEY;
const dbUrl = process.env.SUPABASE_DB_URL;
const runId = process.env.GITHUB_RUN_ID ?? `local-${Date.now()}`;
const coreSha = process.env.GITHUB_SHA ?? 'unknown';
const centralSha = process.env.CENTRAL_CERTIFIED_SHA ?? 'unknown';
const outDir = 'artifacts/step1-certification';
const prefix = `step1-cert-${runId}-${randomBytes(3).toString('hex')}`;
const password = `${randomBytes(18).toString('base64url')}aA1!`;
const evidence = {
  schema_version: 1,
  staging_project: projectRef,
  production_accessed: false,
  github_run_id: runId,
  core_sha: coreSha,
  central_sha: centralSha,
  started_at: new Date().toISOString(),
  tests: [],
  contention_rounds: [],
  cleanup: { attempted: false, completed: false },
};
const users = {};

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

function record(group, name, status, detail = {}) {
  evidence.tests.push({ group, name, status, ...detail });
  console.log(`${status}: ${group} — ${name}`);
}

function sql(statement, vars = {}) {
  const args = [dbUrl, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-A', '-t'];
  for (const [key, value] of Object.entries(vars)) args.push('-v', `${key}=${value}`);
  return execFileSync('psql', args, { input: statement, encoding: 'utf8', stdio: ['pipe', 'pipe', 'pipe'] }).trim();
}

async function api(path, { token, method = 'POST', body, headers = {} } = {}) {
  const response = await fetch(`${url}${path}`, {
    method,
    headers: {
      apikey: publishableKey,
      'content-type': 'application/json',
      ...(token ? { authorization: `Bearer ${token}` } : {}),
      ...headers,
    },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await response.text();
  let data = null;
  try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: response.status, ok: response.ok, data };
}

async function createUser(label, role) {
  const email = `${prefix}-${label}@example.invalid`;
  const signup = await api('/auth/v1/signup', { body: { email, password } });
  assert(signup.status < 500, `Auth signup infrastructure failed for ${label}: HTTP ${signup.status}`);
  const id = signup.data?.user?.id ?? signup.data?.id;
  assert(id, `Auth signup did not return a user id for ${label}: HTTP ${signup.status}`);
  users[label] = { id, email, role };
}

async function signIn(label) {
  const user = users[label];
  const response = await api('/auth/v1/token?grant_type=password', { body: { email: user.email, password } });
  assert(response.ok && response.data?.access_token, `Password sign-in failed for ${label}: HTTP ${response.status}`);
  user.token = response.data.access_token;
}

async function rpc(label, name, body) {
  return api(`/rest/v1/rpc/${name}`, { token: users[label].token, body });
}

async function directPatch(label, table, query, body) {
  return api(`/rest/v1/${table}?${query}`, {
    token: users[label].token,
    method: 'PATCH',
    body,
    headers: { prefer: 'return=representation' },
  });
}

function setupSql() {
  const readiness = JSON.stringify(['client', 'product', 'quantity', 'address', 'payment_terms'].map(dimension => ({ dimension, status: 'ready', score: 100 })));
  const ids = {
    company: randomUUID(), product: randomUUID(), authorityOrder: randomUUID(), cartonOrder: randomUUID(),
    carton1: randomUUID(), carton2: randomUUID(), scan1: randomUUID(), scan2: randomUUID(), badScan: randomUUID(),
  };
  evidence.fixture_ids = { ...ids };
  sql(`
    update auth.users set email_confirmed_at=now(), updated_at=now()
      where email like :'prefix' || '%';
    insert into public.users(id,email,name,full_name,role,is_active)
    values
      (:'finance','${users.finance.email}',:'prefix'||'-finance',:'prefix'||'-finance','FINANCE_EXEC',true),
      (:'sales','${users.sales.email}',:'prefix'||'-sales',:'prefix'||'-sales','SALES_EXECUTIVE',true),
      (:'packing','${users.packing.email}',:'prefix'||'-packing',:'prefix'||'-packing','PACKING_SUPERVISOR',true),
      (:'gate','${users.gate.email}',:'prefix'||'-gate',:'prefix'||'-gate','GATE_SECURITY',true),
      (:'support','${users.support.email}',:'prefix'||'-support',:'prefix'||'-support','SUPPORT_EXECUTIVE',true),
      (:'outsider','${users.outsider.email}',:'prefix'||'-outsider',:'prefix'||'-outsider','BUYER',true);
    insert into public.user_role_map(user_id,role_id)
    select v.user_id,r.id
    from (values
      (:'finance'::uuid,'FINANCE_EXEC'),
      (:'sales'::uuid,'SALES_EXECUTIVE'),
      (:'packing'::uuid,'PACKING_SUPERVISOR'),
      (:'gate'::uuid,'GATE_SECURITY'),
      (:'support'::uuid,'SUPPORT_EXECUTIVE')
    ) as v(user_id,role_key)
    join public.roles r on upper(r.role_key)=v.role_key and coalesce(r.is_active,true)
    on conflict do nothing;
    insert into public.companies(id,business_name,gst_number,registered_address,status,payment_terms)
      values(:'company',:'prefix','07AACCC'||substr(md5(:'prefix'),1,4)||'A1Z5','New Delhi','approved','prepaid');
    insert into public.products(id,name,category,sku,hsn_code,price_per_kg,base_price,price_b2b,primary_pack_weight_kg)
      values(:'product',:'prefix'||'-product','Baklawa',:'prefix'||'-sku','1905',100,100,100,1);
    insert into public.orders(id,company_id,status,order_number,sales_order_value,advance_required,advance_paid,payment_status,payment_cleared,final_invoice_url,order_origin,tracking_token)
      values
      (:'authority_order',:'company','submitted',:'prefix'||'-AUTH',100,30,59,'advance_paid',false,'https://example.invalid/invoice','LEGACY_ERP',md5(:'prefix'||'-AUTH')),
      (:'carton_order',:'company','cleared_for_dispatch',:'prefix'||'-CARTON',100,0,100,'paid',true,'https://example.invalid/invoice','LEGACY_ERP',md5(:'prefix'||'-CARTON'));
    insert into public.order_items(order_id,product_id,quantity,production_status,actual_packed_qty)
      values(:'authority_order',:'product',1,'completed',1),(:'carton_order',:'product',2,'completed',2);
    insert into public.order_payments(order_id,company_id,payment_type,amount,reference_no,status,verified_by,verified_at)
      values(:'authority_order',:'company','balance',70,:'prefix'||'-PAY','verified',:'finance',now());
    insert into public.dispatch_cartons(id,order_id,barcode_string,box_number,total_boxes,status)
      values(:'carton1',:'carton_order',:'prefix'||'-C1',1,2,'labeled'),(:'carton2',:'carton_order',:'prefix'||'-C2',2,2,'labeled');
    insert into public.operational_scan_records(id,scan_type,verification_type,entity_type,entity_id,order_id,barcode_value,expected_barcode,verification_status,scan_source,correlation_id)
      values
      (:'scan1','dispatch_gate','gate_check','dispatch_carton',:'carton1',:'carton_order',:'prefix'||'-C1',:'prefix'||'-C1','verified','step1_cert',:'prefix'||'-scan1'),
      (:'scan2','dispatch_gate','gate_check','dispatch_carton',:'carton2',:'carton_order',:'prefix'||'-C2',:'prefix'||'-C2','verified','step1_cert',:'prefix'||'-scan2'),
      (:'bad_scan','dispatch_gate','gate_check','dispatch_carton',:'carton2',:'carton_order','WRONG',:'prefix'||'-C2','mismatch','step1_cert',:'prefix'||'-bad');
  `, { prefix, finance: users.finance.id, sales: users.sales.id, packing: users.packing.id, gate: users.gate.id, support: users.support.id, outsider: users.outsider.id,
    company: ids.company, product: ids.product, authority_order: ids.authorityOrder, carton_order: ids.cartonOrder,
    carton1: ids.carton1, carton2: ids.carton2, scan1: ids.scan1, scan2: ids.scan2, bad_scan: ids.badScan });
  evidence.readiness_fixture = readiness;
}

async function authorityMatrix() {
  const order = evidence.fixture_ids.authorityOrder;
  let r = await rpc('finance', 'update_order_finance_verification_v1', { p_order_id: order, p_payment_status: 'advance_paid' });
  assert(r.ok && r.data?.ok === true, 'Authorized finance verification failed');
  record('authority', 'authorized finance verification', 'PASS');

  r = await rpc('outsider', 'update_order_finance_verification_v1', { p_order_id: order, p_payment_status: 'paid' });
  assert(!r.ok, 'Unauthorized finance transition unexpectedly succeeded');
  record('authority', 'unauthorized finance transition denied', 'PASS', { http_status: r.status });

  r = await directPatch('finance', 'orders', `id=eq.${order}`, { status: 'dispatched' });
  assert(!r.ok || !Array.isArray(r.data) || r.data.length === 0, 'Direct governed order status mutation succeeded');
  assert(sql(`select status from public.orders where id=:'id'`, { id: order }) !== 'dispatched', 'Direct order write changed state');
  record('authority', 'direct order status bypass denied', 'PASS', { http_status: r.status });

  r = await rpc('sales', 'confirm_prepaid_order_awaiting_advance_v1', { p_order_id: order });
  assert(r.ok && r.data?.ok === true, 'Authorized prepaid confirmation failed');
  assert(sql(`select status from public.orders where id=:'id'`, { id: order }) === 'awaiting_advance', 'Prepaid confirmation state mismatch');
  record('authority', 'prepaid confirmation derives awaiting_advance', 'PASS');

  // Confirmation intentionally resets the order to awaiting_receipt. Finance
  // must then verify the stored payment state; production release must never
  // derive authority from the caller-supplied compatibility parameter.
  r = await rpc('finance', 'update_order_finance_verification_v1', { p_order_id: order, p_payment_status: 'advance_paid' });
  assert(r.ok && r.data?.ok === true, 'Post-confirmation finance verification failed');

  r = await rpc('finance', 'release_order_to_in_production_v1', { p_order_id: order, p_payment_status: 'advance_paid' });
  assert(r.ok && r.data?.ok === true, 'Authorized production release failed');
  record('authority', 'authorized production release', 'PASS');

  r = await rpc('packing', 'release_order_to_packed_ready_v1', { p_order_id: order });
  assert(r.ok && r.data?.ok === true, 'Authorized packed-ready transition failed');
  record('authority', 'authorized packed-ready transition', 'PASS');

  r = await rpc('outsider', 'clear_order_for_dispatch_v1', { p_order_id: order });
  assert(!r.ok, 'Unauthorized dispatch clearance succeeded');
  record('authority', 'unauthorized dispatch clearance denied', 'PASS', { http_status: r.status });

  r = await rpc('finance', 'record_order_fully_paid_v1', { p_order_id: order });
  assert(r.ok && r.data?.ok === true, 'Fully-paid recording failed');
  r = await rpc('finance', 'clear_order_for_dispatch_v1', { p_order_id: order });
  assert(r.ok && r.data?.ok === true, 'Authorized dispatch clearance failed');
  record('authority', 'full-payment projection and dispatch clearance', 'PASS');

  r = await directPatch('outsider', 'dispatch_cartons', `id=eq.${evidence.fixture_ids.carton1}`, { status: 'physically_dispatched' });
  assert(!r.ok || !Array.isArray(r.data) || r.data.length === 0, 'Direct governed carton mutation succeeded');
  assert(sql(`select status from public.dispatch_cartons where id=:'id'`, { id: evidence.fixture_ids.carton1 }) === 'labeled', 'Direct carton write changed state');
  record('authority', 'direct carton mutation denied', 'PASS', { http_status: r.status });

  r = await rpc('outsider', 'release_carton_at_dispatch_gate_v1', { p_carton_id: evidence.fixture_ids.carton1, p_scan_evidence_id: evidence.fixture_ids.scan1 });
  assert(!r.ok, 'Unauthorized gate role succeeded');
  record('authority', 'unauthorized gate role denied', 'PASS', { http_status: r.status });
}

async function waConcurrency() {
  const readiness = ['client', 'product', 'quantity', 'address', 'payment_terms'].map(dimension => ({ dimension, status: 'ready', score: 100 }));
  for (let round = 1; round <= 3; round++) {
    const draft = randomUUID();
    const key = `${prefix}-wa-${round}`;
    sql(`
      with cert_contact as (
        insert into public.whatsapp_contacts(phone_number) values (substr(md5(:'draft'),1,20)) returning id
      ), cert_packet as (
        insert into public.whatsapp_message_packets(contact_id,stitched_content,first_message_at,last_message_at)
        select id,'{}'::jsonb,now(),now() from cert_contact returning id
      )
      insert into public.sales_order_drafts(id,packet_id,extraction_request_key,status,company_id,company_name,readiness_overall_score,readiness_dimensions,original_whatsapp_text,created_by,updated_by)
      values(:'draft',(select id from cert_packet),:'key','UNDER_REVIEW',:'company',:'prefix',100,:'readiness'::jsonb,:'prefix',:'actor',:'actor');
      insert into public.sales_order_draft_lines(draft_id,line_index,product_id,product_name,sku,raw_quantity,raw_unit,normalized_quantity,normalized_unit,operator_quantity)
      values(:'draft',0,:'product',:'prefix'||'-product',:'prefix'||'-sku',2,'Pack',2,'Pack',2);
    `, { draft, key, company: evidence.fixture_ids.company, prefix, readiness: JSON.stringify(readiness), actor: users.support.id, product: evidence.fixture_ids.product });

    const body = { p_draft_id: draft, p_expected_extraction_request_key: key, p_actor_id: users.support.id, p_actor_name: `${prefix}-support`, p_review_notes: 'Step 1 certification', p_metadata: { source: 'step1-certification' } };
    const attempts = await Promise.all(Array.from({ length: 10 }, () => rpc('support', 'approve_sales_order_draft_for_so_atomic', body)));
    assert(attempts.every(x => x.ok && Array.isArray(x.data) && x.data.length === 1), `WA contention round ${round} had failed responses`);
    const orderIds = new Set(attempts.map(x => x.data[0].promoted_order_id));
    assert(orderIds.size === 1, `WA contention round ${round} returned multiple order ids`);
    const promotedOrderId = [...orderIds][0];
    const counts = sql(`select count(*)||','||(select count(*) from public.order_items where order_id=:'order') from public.orders where id=:'order'`, { order: promotedOrderId });
    assert(counts === '1,1', `WA round ${round} did not produce exactly one order/line: ${counts}`);
    assert(attempts.filter(x => x.data[0].already_promoted === false).length === 1, `WA round ${round} first-promotion cardinality mismatch`);
    const retry = await rpc('support', 'approve_sales_order_draft_for_so_atomic', body);
    assert(retry.ok && retry.data[0].already_promoted === true && retry.data[0].promoted_order_id === promotedOrderId, `WA round ${round} retry was not stable`);
    const invalid = await rpc('support', 'approve_sales_order_draft_for_so_atomic', { ...body, p_expected_extraction_request_key: `${key}-forged` });
    assert(!invalid.ok, `WA round ${round} accepted forged idempotency key`);
    evidence.contention_rounds.push({ round, attempts: 10, canonical_order_id: promotedOrderId, orders: 1, order_lines: 1, first_promotions: 1, retries_stable: true, forged_key_denied: true });
    record('wa_concurrency', `round ${round}: one canonical order under contention`, 'PASS', { canonical_order_id: promotedOrderId, attempts: 10 });
  }

  const badDraft = randomUUID();
  sql(`with cert_contact as (insert into public.whatsapp_contacts(phone_number) values (substr(md5(:'draft'),1,20)) returning id),
       cert_packet as (insert into public.whatsapp_message_packets(contact_id,stitched_content,first_message_at,last_message_at) select id,'{}'::jsonb,now(),now() from cert_contact returning id)
       insert into public.sales_order_drafts(id,packet_id,extraction_request_key,status,company_id,readiness_overall_score,readiness_dimensions,original_whatsapp_text)
       values(:'draft',(select id from cert_packet),:'key','UNDER_REVIEW',:'company',0,'[]','invalid fixture')`, { draft: badDraft, key: `${prefix}-invalid`, company: evidence.fixture_ids.company });
  const failed = await rpc('support', 'approve_sales_order_draft_for_so_atomic', { p_draft_id: badDraft, p_expected_extraction_request_key: `${prefix}-invalid`, p_actor_id: users.support.id, p_actor_name: `${prefix}-support`, p_metadata: {} });
  assert(!failed.ok, 'Invalid WA draft unexpectedly promoted');
  assert(sql(`select (promoted_order_id is null)::text||','||status from public.sales_order_drafts where id=:'draft'`, { draft: badDraft }) === 'true,UNDER_REVIEW', 'Failed WA validation left partial promotion state');
  record('wa_concurrency', 'failed validation rolls back without partial promotion', 'PASS');
}

async function cartonIsolation() {
  const ids = evidence.fixture_ids;
  let r = await rpc('gate', 'release_carton_at_dispatch_gate_v1', { p_carton_id: ids.carton2, p_scan_evidence_id: ids.badScan });
  assert(r.ok && r.data?.ok === false, 'Mismatched barcode evidence did not fail closed');
  assert(sql(`select status from public.dispatch_cartons where id=:'id'`, { id: ids.carton2 }) === 'labeled', 'Rejected barcode changed carton state');
  record('carton', 'carton-boundary/barcode violation preserves state', 'PASS');

  r = await rpc('gate', 'release_carton_at_dispatch_gate_v1', { p_carton_id: ids.carton1, p_scan_evidence_id: ids.scan1 });
  assert(r.ok && r.data?.ok === true && r.data.remaining_cartons === 1, 'First carton release failed isolation check');
  let states = sql(`select string_agg(box_number||':'||status,',' order by box_number) from public.dispatch_cartons where order_id=:'id'`, { id: ids.cartonOrder });
  assert(states === '1:physically_dispatched,2:labeled', `Partial carton state mismatch: ${states}`);
  assert(sql(`select status from public.orders where id=:'id'`, { id: ids.cartonOrder }) === 'cleared_for_dispatch', 'Physical gate release falsely dispatched order');
  record('carton', 'partial release affects one carton only and not order dispatch status', 'PASS', { states });

  r = await rpc('gate', 'release_carton_at_dispatch_gate_v1', { p_carton_id: ids.carton1, p_scan_evidence_id: ids.scan1 });
  assert(r.ok && r.data?.ok === true && r.data.already_released === true, 'Duplicate carton release was not idempotent');
  record('carton', 'duplicate release is idempotent', 'PASS');

  r = await rpc('gate', 'release_carton_at_dispatch_gate_v1', { p_carton_id: ids.carton2, p_scan_evidence_id: ids.scan2 });
  assert(r.ok && r.data?.ok === true && r.data.remaining_cartons === 0, 'Final carton release failed');
  states = sql(`select string_agg(box_number||':'||status,',' order by box_number) from public.dispatch_cartons where order_id=:'id'`, { id: ids.cartonOrder });
  assert(states === '1:physically_dispatched,2:physically_dispatched', `Final carton states mismatch: ${states}`);
  assert(sql(`select status from public.orders where id=:'id'`, { id: ids.cartonOrder }) === 'cleared_for_dispatch', 'Final physical release bypassed governed order dispatch authority');
  record('carton', 'multi-carton release preserves separate order dispatch authority', 'PASS', { states });
}

function cleanup() {
  evidence.cleanup.attempted = true;
  try {
    sql(`
      -- Governed orders, gate decisions, scans, draft audits, and authority audits are
      -- deliberately retained as immutable certification evidence. Cleanup removes
      -- credentials and the one validation-only draft that created no audit record.
      delete from public.sales_order_draft_lines where draft_id in
        (select id from public.sales_order_drafts where extraction_request_key=:'prefix'||'-invalid');
      delete from public.sales_order_drafts where extraction_request_key=:'prefix'||'-invalid';
      delete from public.users where email like :'prefix'||'%';
      delete from auth.identities where user_id in (select id from auth.users where email like :'prefix'||'%');
      delete from auth.users where email like :'prefix'||'%';
    `, { prefix });
    evidence.cleanup.completed = true;
  } catch (error) {
    evidence.cleanup.error = String(error.message).slice(0, 500);
  }
  const remaining = sql(`select
    (select count(*) from auth.users where email like :'prefix'||'%') +
    (select count(*) from public.users where email like :'prefix'||'%') +
    (select count(*) from public.sales_order_drafts where extraction_request_key=:'prefix'||'-invalid')`, { prefix });
  evidence.cleanup.remaining_mutable_fixtures = Number(remaining);
  evidence.cleanup.retained_governed_evidence = {
    orders: Number(sql(`select count(*) from public.orders where order_number like :'prefix'||'%'`, { prefix }) || 0),
    drafts: Number(sql(`select count(*) from public.sales_order_drafts where extraction_request_key like :'prefix'||'%'`, { prefix }) || 0),
    gate_decisions: Number(sql(`select count(*) from public.dispatch_gate_decisions where carton_id in (select id from public.dispatch_cartons where barcode_string like :'prefix'||'%')`, { prefix }) || 0),
    audit_rows: Number(sql(`select count(*) from public.audit_logs where entity_id in (select id::text from public.orders where order_number like :'prefix'||'%')`, { prefix }) || 0),
    reason: 'Retained because Wave 1B/1C append-only controls forbid destructive cleanup of certification evidence.',
  };
  assert(Number(remaining) === 0, `Cleanup left ${remaining} mutable fixtures`);
}

function writeEvidence() {
  mkdirSync(outDir, { recursive: true });
  evidence.completed_at = new Date().toISOString();
  evidence.result = evidence.tests.every(test => test.status === 'PASS') && evidence.cleanup.remaining_mutable_fixtures === 0 ? 'PASS' : 'FAIL';
  writeFileSync(`${outDir}/certification.json`, `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
  const rows = evidence.tests.map(t => `| ${t.group} | ${t.name} | ${t.status} |`).join('\n');
  writeFileSync(`${outDir}/certification.md`, `# Oasis App-Verse Step 1 certification\n\n- Core SHA: \`${coreSha}\`\n- Central SHA: \`${centralSha}\`\n- GitHub run: \`${runId}\`\n- Staging project: \`${projectRef}\`\n- Result: **${evidence.result}**\n- Production was not accessed.\n- Mutable fixture cleanup: **${evidence.cleanup.remaining_mutable_fixtures === 0 ? 'PASS' : 'FAIL'}**\n\n| Group | Assertion | Result |\n|---|---|---|\n${rows}\n`, { mode: 0o600 });
}

let failure;
try {
  assert(projectRef === 'tcxvcatsqqertcnycuop', 'Unexpected project reference');
  assert(url === `https://${projectRef}.supabase.co`, 'Refusing non-staging API target');
  assert(dbUrl?.includes(projectRef), 'Refusing non-staging database target');
  for (const [label, role] of Object.entries({ finance: 'FINANCE_EXEC', sales: 'SALES_EXECUTIVE', packing: 'PACKING_SUPERVISOR', gate: 'GATE_SECURITY', support: 'SUPPORT_EXECUTIVE', outsider: 'BUYER' })) await createUser(label, role);
  setupSql();
  for (const label of Object.keys(users)) await signIn(label);
  record('authentication', 'six role-distinct password/JWT sessions established', 'PASS');
  await authorityMatrix();
  await waConcurrency();
  await cartonIsolation();
} catch (error) {
  failure = error;
  record('harness', 'certification execution', 'FAIL', { error: String(error.message).slice(0, 800) });
} finally {
  try { cleanup(); } catch (error) {
    failure ??= error;
    evidence.cleanup.error = String(error.message).slice(0, 800);
  }
  writeEvidence();
}

if (failure) throw failure;
console.log(`PASS: Step 1 staging certification (${evidence.tests.length} assertions)`);
