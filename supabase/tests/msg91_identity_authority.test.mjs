// Real-PostgreSQL behavioural tests for the MSG91 identity authority migration.
// Requires MSG91_TEST_PG_ADMIN_URL (a superuser libpq URI/conninfo to a scratch server).
// In CI the variable is always provided; a missing variable FAILS there rather than skipping.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { readFileSync } from "node:fs";
import pg from "pg"; // scratch-database client only (installed with `npm install --no-save pg@8.13.1`)
import { canonicalIndianPhone } from "../functions/msg91-otp/strict-phone-match.mjs";

const ADMIN = process.env.MSG91_TEST_PG_ADMIN_URL;
if (!ADMIN && process.env.CI) throw new Error("MSG91_TEST_PG_ADMIN_URL is required in CI");
const skip = ADMIN ? false : "MSG91_TEST_PG_ADMIN_URL not set (local run without a scratch Postgres)";

const migrations = [
  "../migrations/20260910040000_b2b_prelogin_access_lifecycle.sql",
  "../migrations/20260912070000_b2b_pending_auth_placeholder_reconciliation.sql",
  "../migrations/20261113124000_msg91_identity_resolution_authority_v1.sql",
];
const DB = `msg91_it_${process.pid}_${Date.now()}`;
const dbUrl = () => { const u = new URL(ADMIN); u.pathname = `/${DB}`; return u.toString(); };
const file = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");

async function withClient(url, fn) {
  const c = new pg.Client({ connectionString: url });
  await c.connect();
  try { return await fn(c); } finally { await c.end(); }
}
// Simple-query protocol: supports multi-statement scripts. Returns the last statement's first cell as text.
async function run(url, sql) {
  return withClient(url, async (c) => {
    const res = await c.query({ text: sql, rowMode: "array" });
    const last = Array.isArray(res) ? res[res.length - 1] : res;
    const cell = last?.rows?.[0]?.[0];
    return cell === undefined || cell === null ? "" : typeof cell === "object" ? JSON.stringify(cell) : String(cell);
  });
}
const q = (sql) => run(dbUrl(), sql);
const resolve = async (phone) => JSON.parse(await q(`select public.resolve_msg91_identity_v1('${phone}')`));
const bind = async (phone, id) => JSON.parse(await q(`select public.bind_msg91_pending_profile_v1('${phone}','${id}')`));
const uid = () => q("select gen_random_uuid()");
const reset = () => q("truncate auth.users, public.users, public.b2b_applications, public.companies, public.audit_logs");
async function authUser({ phone, email, phoneConfirmed = true, emailConfirmed = true }) {
  const id = await uid();
  await q(`insert into auth.users(id,email,phone,phone_confirmed_at,email_confirmed_at) values ('${id}',${email ? `'${email}'` : "null"},${phone ? `'${phone}'` : "null"},${phoneConfirmed ? "now()" : "null"},${emailConfirmed ? "now()" : "null"})`);
  return id;
}
async function publicUser(cols) {
  const id = cols.id || (await uid());
  const keys = ["id", "role", ...Object.keys(cols).filter((k) => k !== "id" && k !== "role")];
  const vals = [`'${id}'`, `'${cols.role || "PENDING"}'`, ...keys.slice(2).map((k) => (cols[k] === null ? "null" : /^(array|now)/.test(String(cols[k])) ? cols[k] : `'${cols[k]}'`))];
  await q(`insert into public.users(${keys.join(",")}) values (${vals.join(",")})`);
  return id;
}

before(async () => {
  if (!ADMIN) return;
  await run(ADMIN, `create database ${DB}`);
  await run(dbUrl(), file("../test-fixtures/msg91_identity_stub_schema.sql"));
  for (const m of migrations) await run(dbUrl(), file(m));
});
after(async () => { if (ADMIN) await run(ADMIN, `drop database if exists ${DB} with (force)`).catch(() => {}); });

test("SQL canonical phone matches the JS canonicalIndianPhone policy", { skip }, async () => {
  const vectors = ["+91 98765 43210", "9876543210", "09876543210", "919876543210", "98765-43210", "9919876543210",
    "1239876543210", "98765432101", "+1 9876543210", "5876543210", "", "abc", "919876543210x", "+91-(987)-654-3210", "00919876543210", "0919876543210"];
  for (const v of vectors) {
    const sql = await q(`select coalesce(public.msg91_canonical_indian_phone_v1('${v}'),'<null>')`);
    assert.equal(sql, canonicalIndianPhone(v) ?? "<null>", `vector ${JSON.stringify(v)}`);
  }
});

test("grants: identity RPCs are service_role only; pure index helpers are executable by writer roles", { skip }, async () => {
  for (const fn of ["resolve_msg91_identity_v1(text)", "bind_msg91_pending_profile_v1(text,uuid)"]) {
    const row = await q(`select concat_ws('|', has_function_privilege('anon','public.${fn}','execute'), has_function_privilege('authenticated','public.${fn}','execute'), has_function_privilege('service_role','public.${fn}','execute'), has_function_privilege('public','public.${fn}','execute'))`);
    assert.equal(row, "f|f|t|f", fn);
  }
  for (const fn of ["msg91_canonical_indian_phone_v1(text)", "msg91_canonical_phones_v1(text[])"]) {
    const row = await q(`select concat_ws('|', has_function_privilege('anon','public.${fn}','execute'), has_function_privilege('authenticated','public.${fn}','execute'), has_function_privilege('service_role','public.${fn}','execute'), has_function_privilege('public','public.${fn}','execute'))`);
    assert.equal(row, "t|t|t|f", fn);
  }
});

test("non-owner writer roles can write indexed phone columns (index maintenance needs helper EXECUTE)", { skip }, async () => {
  await reset();
  // Table privileges follow the real baseline (direct b2b_applications INSERT is revoked from app roles by
  // 20260910040000), so each role only performs operations it is genuinely allowed to perform.
  await q("insert into public.b2b_applications(id,status,contact_phone,mobile_number) values ('00000000-0000-4000-8000-0000000000a1','pending','9876543210','9876543211')");
  for (const role of ["authenticated", "anon", "service_role"]) {
    await q(`begin; set local role ${role};
      insert into public.users(id,role,phone,mobile_number,secondary_phones) values (gen_random_uuid(),'PENDING','9876543210','9876543211',array['9876543212']);
      update public.users set phone='9876543299', secondary_phones=array['9876543298'] where phone='9876543210';
      insert into public.companies(phone) values ('9876543210');
      update public.companies set phone='9876543266' where phone='9876543210';
      rollback;`);
  }
  for (const role of ["authenticated", "service_role"]) {
    await q(`begin; set local role ${role};
      update public.b2b_applications set contact_phone='9876543277', mobile_number='9876543278' where id='00000000-0000-4000-8000-0000000000a1';
      rollback;`);
  }
  // The identity RPCs stay unreachable for those roles.
  for (const role of ["authenticated", "anon"]) {
    await assert.rejects(() => q(`begin; set local role ${role}; select public.resolve_msg91_identity_v1('9876543210'); rollback;`), /permission denied/i, role);
  }
});

test("new phone with no Auth and no public identity resolves to none/absent", { skip }, async () => {
  await reset();
  const r = await resolve("+91 98765 43210");
  assert.equal(r.status, "none");
  assert.equal(r.auth_state, "absent");
});

test("existing user matches by primary, mobile and formatted secondary phone; never by embedded suffix", { skip }, async () => {
  await reset();
  const a = await publicUser({ phone: "+91 98765 43210" });
  let r = await resolve("9876543210");
  assert.deepEqual([r.status, r.public_user_id], ["existing", a]);
  await reset();
  const b = await publicUser({ mobile_number: "09876543210" });
  assert.equal((await resolve("919876543210")).public_user_id, b);
  await reset();
  const c = await publicUser({ secondary_phones: "array['00','98765-43210']::text[]" });
  assert.equal((await resolve("+919876543210")).public_user_id, c);
  await reset();
  await publicUser({ phone: "9919876543210" }); // embeds the verified number as a suffix of a longer number
  await publicUser({ phone: "98765432101" });
  assert.equal((await resolve("9876543210")).status, "none");
});

test("two public identities for one phone fail closed as duplicate", { skip }, async () => {
  await reset();
  await publicUser({ phone: "9876543210" });
  await publicUser({ secondary_phones: "array['+919876543210']::text[]" });
  assert.equal((await resolve("9876543210")).status, "duplicate_phone_identity");
});

test("company-linked phone without a claimable application is ambiguous; approved unclaimed application is a pending claim", { skip }, async () => {
  await reset();
  const co = await uid();
  await q(`insert into public.companies(id,phone) values ('${co}','98765 43210')`);
  await publicUser({ company_id: co, phone: "9000000001" });
  assert.equal((await resolve("9876543210")).status, "ambiguous_phone_identity");
  await q(`insert into public.b2b_applications(status,user_id,resolved_company_id,contact_phone) values ('approved',null,'${co}','9876543210')`);
  const r = await resolve("9876543210");
  assert.equal(r.status, "none");
  assert.equal(r.approved_b2b_pending_claim, true);
});

test("orphan Auth recovery: exact deterministic email + confirmed matching phone is recoverable", { skip }, async () => {
  await reset();
  const id = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  const r = await resolve("9876543210");
  assert.deepEqual([r.status, r.auth_state, r.auth_user_id], ["none", "orphan_recoverable", id]);
  await reset();
  const id2 = await authUser({ phone: "+919876543210", email: "919876543210@phone.oasis.local" });
  assert.equal((await resolve("9876543210")).auth_user_id, id2);
});

test("takeover guards: unconfirmed, email-only, phone-only or split-identity Auth rows are conflicts", { skip }, async () => {
  const em = "919876543210@phone.oasis.local";
  for (const [label, setup] of [
    ["email-only pre-registered", () => authUser({ phone: null, email: em, emailConfirmed: false })],
    ["email-only confirmed but no phone", () => authUser({ phone: null, email: em })],
    ["phone unconfirmed", () => authUser({ phone: "919876543210", email: em, phoneConfirmed: false })],
    ["email unconfirmed", () => authUser({ phone: "919876543210", email: em, emailConfirmed: false })],
    ["phone owned by non-deterministic email", () => authUser({ phone: "919876543210", email: "someone@else.com" })],
    ["email and phone on different Auth users", async () => { await authUser({ phone: null, email: em }); await authUser({ phone: "919876543210", email: "x@y.z" }); }],
  ]) {
    await reset();
    await setup();
    const r = await resolve("9876543210");
    assert.deepEqual([r.status, r.auth_state, r.auth_user_id ?? null], ["none", "conflict", null], label);
  }
});

test("bind creates the PENDING profile atomically, is idempotent, and refuses unsafe states", { skip }, async () => {
  await reset();
  const id = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  assert.equal((await bind("9876543210", id)).status, "created");
  assert.equal(await q(`select role||'|'||phone from public.users where id='${id}'`), "PENDING|+919876543210");
  assert.equal((await bind("9876543210", id)).status, "exists"); // retry after lost response
  assert.equal(await q("select count(*) from public.users"), "1");
  assert.equal((await resolve("9876543210")).public_user_id, id);
  // wrong auth id never binds
  await reset();
  await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  assert.equal((await bind("9876543210", await uid())).status, "auth_identity_invalid");
  assert.equal(await q("select count(*) from public.users"), "0");
  // a different public identity already owns the phone
  await reset();
  const orphan = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  await publicUser({ phone: "9876543210" });
  assert.equal((await bind("9876543210", orphan)).status, "public_identity_conflict");
  assert.equal(await q("select count(*) from public.users"), "1");
  // a pre-existing unbound row with the Auth id is not silently adopted
  await reset();
  const o2 = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  await publicUser({ id: o2, phone: "9000000002" });
  assert.equal((await bind("9876543210", o2)).status, "public_identity_conflict");
});

test("failed profile write then retry recovers the orphan without duplicate Auth or deletion", { skip }, async () => {
  await reset();
  const id = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  // simulated failure: profile never written. Retry classification finds the same orphan.
  assert.equal((await resolve("9876543210")).auth_user_id, id);
  assert.equal((await bind("9876543210", id)).status, "created");
  assert.equal(await q("select count(*) from auth.users"), "1");
});

test("legacy placeholder: resolves to the placeholder, and after reconcile resolves to the new Auth identity", { skip }, async () => {
  await reset();
  const placeholder = await publicUser({ phone: "9876543210", role: "PENDING" });
  await q(`insert into public.b2b_applications(status,user_id,contact_phone) values ('pending',null,'9876543210')`);
  const r = await resolve("9876543210");
  assert.deepEqual([r.status, r.public_user_id], ["existing", placeholder]); // Edge then reports phone_linked_to_missing_auth_identity
  assert.equal(await q("select concat(eligible,'|',reason) from public.inspect_b2b_pending_phone_placeholder_v1('9876543210')"), "t|eligible");
  const newAuth = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  await q(`select * from public.reconcile_b2b_pending_phone_placeholder_v1('9876543210','${placeholder}','${newAuth}')`);
  const after = await resolve("9876543210");
  assert.deepEqual([after.status, after.public_user_id], ["existing", newAuth]);
  assert.equal(await q(`select concat(is_active::text,'|',coalesce(phone,'null')) from public.users where id='${placeholder}'`), "false|null");
});

test("concurrency: a resolve blocks behind an in-flight bind and then observes the committed identity", { skip }, async () => {
  await reset();
  const id = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  const holder = q(`begin; select public.bind_msg91_pending_profile_v1('9876543210','${id}'); select pg_sleep(1.5); commit;`);
  await new Promise((r) => setTimeout(r, 400));
  const t0 = Date.now();
  const seen = JSON.parse(await q("select public.resolve_msg91_identity_v1('9876543210')"));
  const ms = Date.now() - t0;
  await holder;
  assert.ok(ms >= 800, `resolve should wait for the lock holder (took ${ms}ms)`);
  assert.deepEqual([seen.status, seen.public_user_id], ["existing", id]);
});

test("concurrency: simultaneous binds for one phone yield exactly one public identity", { skip }, async () => {
  await reset();
  // Auth uniqueness means only one Auth row can be the phone's orphan; race bind(A) against an
  // unrelated Auth user B. B must be refused (auth_identity_invalid before A commits, or
  // public_identity_conflict after), and exactly one profile may exist.
  const a = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  const b = await authUser({ phone: "919999999999", email: "919999999999@phone.oasis.local" });
  const results = await Promise.all([
    q(`select public.bind_msg91_pending_profile_v1('9876543210','${a}')`),
    q(`select public.bind_msg91_pending_profile_v1('9876543210','${b}')`),
    q(`select public.bind_msg91_pending_profile_v1('9876543210','${a}')`),
  ]);
  const statuses = results.map((r) => JSON.parse(r).status).sort();
  assert.equal(statuses.filter((x) => x === "created").length, 1, JSON.stringify(statuses));
  assert.ok(statuses.every((x) => ["created", "exists", "auth_identity_invalid", "public_identity_conflict"].includes(x)), JSON.stringify(statuses));
  assert.equal(await q("select count(*) from public.users where phone is not null"), "1");
  assert.equal(await q(`select count(*) from public.users where id='${b}'`), "0");
});

test("scale: lookup uses canonical-phone indexes and stays fast with 150k users (no 1000-row ceiling)", { skip }, async () => {
  await reset();
  await q(`insert into public.users(id,role,phone,secondary_phones)
     select gen_random_uuid(),'PENDING','+91'||(7000000000+g)::text, array['+91'||(8000000000+g)::text] from generate_series(1,150000) g;
     insert into auth.users(email,phone,phone_confirmed_at,email_confirmed_at)
     select '91'||(6000000000+g)::text||'@phone.oasis.local','91'||(6000000000+g)::text, now(), now() from generate_series(1,50000) g;
     analyze public.users; analyze auth.users;`);
  const target = await publicUser({ phone: "+91 91234 56789" });
  await q("analyze public.users");
  const t0 = Date.now();
  const r = await resolve("9123456789");
  const ms = Date.now() - t0;
  assert.deepEqual([r.status, r.public_user_id], ["existing", target]);
  const sec = await publicUser({ secondary_phones: "array['+91 90000 00001']::text[]" });
  assert.equal((await resolve("9000000001")).public_user_id, sec);
  assert.equal((await resolve("6000000777")).auth_user_id, await q("select id from auth.users where email='916000000777@phone.oasis.local'"));
  const plan = await withClient(dbUrl(), async (c) => (await c.query(`explain select id from public.users u where public.msg91_canonical_indian_phone_v1(u.phone)='919123456789' or public.msg91_canonical_indian_phone_v1(u.mobile_number)='919123456789' or public.msg91_canonical_phones_v1(u.secondary_phones) @> array['919123456789']`)).rows.map((x) => x["QUERY PLAN"]).join("\n"));
  const authPlan = await withClient(dbUrl(), async (c) => (await c.query(`explain select au.id from auth.users au where au.email = '916000000777@phone.oasis.local'`)).rows.map((x) => x["QUERY PLAN"]).join("\n"));
  const authPhonePlan = await withClient(dbUrl(), async (c) => (await c.query(`explain select au.id from auth.users au where au.phone in ('916000000777','+916000000777')`)).rows.map((x) => x["QUERY PLAN"]).join("\n"));
  assert.match(authPlan, /Index (Only )?Scan|Bitmap Index Scan/, authPlan);
  assert.doesNotMatch(authPlan, /Seq Scan on users/);
  assert.match(authPhonePlan, /Index (Only )?Scan|Bitmap Index Scan/, authPhonePlan);
  assert.doesNotMatch(plan, /Seq Scan on users/);
  assert.match(plan, /Bitmap Index Scan|Index Scan/);
  assert.ok(ms < 1500, `resolve took ${ms}ms`);
});

test("concurrency: a competing B2B claim writer (b2b_identity_mobile lock) is serialised with bind; never two public identities", { skip }, async () => {
  await reset();
  const id = await authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  // Emulates claim_approved_b2b_access_request_v2: take the mobile lock, then write public.users.phone,
  // hold the transaction open, then commit.
  const claimWriter = q(`begin;
    select pg_advisory_xact_lock(hashtextextended('b2b_identity_mobile:919876543210', 0));
    insert into public.users(id,role,phone) values (gen_random_uuid(),'b2b_buyer','+919876543210');
    select pg_sleep(1.2);
    commit;`);
  await new Promise((r) => setTimeout(r, 300));
  const t0 = Date.now();
  const res = JSON.parse(await q(`select public.bind_msg91_pending_profile_v1('9876543210','${id}')`));
  const ms = Date.now() - t0;
  await claimWriter;
  assert.ok(ms >= 600, `bind should wait for the claim writer (took ${ms}ms)`);
  assert.equal(res.status, "public_identity_conflict", JSON.stringify(res));
  assert.equal(await q("select count(*) from public.users where phone like '%9876543210'"), "1");
  assert.equal(await q(`select count(*) from public.users where id='${id}'`), "0");
});

test("reserved phone aliases require fresh admin authorization at commit", { skip }, async () => {
  await reset();
  await authUser({ phone: "916000000100", email: "916000000100@phone.oasis.local" });
  await q(file("../migrations/20261113124100_msg91_reserved_phone_alias_guard_v1.sql"));
  await q(file("../test-fixtures/msg91_reserved_phone_alias_contract.sql"));
});
