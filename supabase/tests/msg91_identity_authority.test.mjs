// Real-PostgreSQL behavioural tests for the MSG91 identity authority migration.
// Requires MSG91_TEST_PG_ADMIN_URL (a superuser libpq URI/conninfo to a scratch server).
// In CI the variable is always provided; a missing variable FAILS there rather than skipping.
import assert from "node:assert/strict";
import { after, before, test } from "node:test";
import { spawn, spawnSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { canonicalIndianPhone } from "../functions/msg91-otp/strict-phone-match.mjs";

const ADMIN = process.env.MSG91_TEST_PG_ADMIN_URL;
if (!ADMIN && process.env.CI) throw new Error("MSG91_TEST_PG_ADMIN_URL is required in CI");
const skip = ADMIN ? false : "MSG91_TEST_PG_ADMIN_URL not set (local run without a scratch Postgres)";

const migrations = [
  "../migrations/20260910040000_b2b_prelogin_access_lifecycle.sql",
  "../migrations/20260912070000_b2b_pending_auth_placeholder_reconciliation.sql",
  "../migrations/20261110150000_msg91_identity_resolution_authority_v1.sql",
];
const DB = `msg91_it_${process.pid}_${Date.now()}`;
const dbUrl = () => ADMIN.replace(/\/[^/?]*(\?|$)/, `/${DB}$1`);
const file = (rel) => readFileSync(new URL(rel, import.meta.url), "utf8");

function psql(url, sql, { allowFail = false } = {}) {
  const r = spawnSync("psql", [url, "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"], { input: sql, encoding: "utf8" });
  if (r.status !== 0 && !allowFail) throw new Error(`psql failed: ${r.stderr}\n${sql.slice(0, 400)}`);
  return { out: r.stdout.trim(), err: r.stderr, status: r.status };
}
const q = (sql) => psql(dbUrl(), sql).out;
const resolve = (phone) => JSON.parse(q(`select public.resolve_msg91_identity_v1('${phone}')`));
const bind = (phone, id) => JSON.parse(q(`select public.bind_msg91_pending_profile_v1('${phone}','${id}')`));
const uid = () => q("select gen_random_uuid()");
const reset = () => q("truncate auth.users, public.users, public.b2b_applications, public.companies, public.audit_logs");
function authUser({ phone, email, phoneConfirmed = true, emailConfirmed = true }) {
  const id = uid();
  q(`insert into auth.users(id,email,phone,phone_confirmed_at,email_confirmed_at) values ('${id}',${email ? `'${email}'` : "null"},${phone ? `'${phone}'` : "null"},${phoneConfirmed ? "now()" : "null"},${emailConfirmed ? "now()" : "null"})`);
  return id;
}
function publicUser(cols) {
  const id = cols.id || uid();
  const keys = ["id", "role", ...Object.keys(cols).filter((k) => k !== "id" && k !== "role")];
  const vals = [`'${id}'`, `'${cols.role || "PENDING"}'`, ...keys.slice(2).map((k) => (cols[k] === null ? "null" : /^(array|now)/.test(String(cols[k])) ? cols[k] : `'${cols[k]}'`))];
  q(`insert into public.users(${keys.join(",")}) values (${vals.join(",")})`);
  return id;
}

before(() => {
  if (!ADMIN) return;
  psql(ADMIN, `create database ${DB}`);
  psql(dbUrl(), file("./fixtures/msg91_identity_stub_schema.sql"));
  for (const m of migrations) psql(dbUrl(), file(m));
});
after(() => { if (ADMIN) psql(ADMIN, `drop database if exists ${DB} with (force)`, { allowFail: true }); });

test("SQL canonical phone matches the JS canonicalIndianPhone policy", { skip }, () => {
  const vectors = ["+91 98765 43210", "9876543210", "09876543210", "919876543210", "98765-43210", "9919876543210",
    "1239876543210", "98765432101", "+1 9876543210", "5876543210", "", "abc", "919876543210x", "+91-(987)-654-3210", "00919876543210", "0919876543210"];
  for (const v of vectors) {
    const sql = q(`select coalesce(public.msg91_canonical_indian_phone_v1('${v}'),'<null>')`);
    assert.equal(sql, canonicalIndianPhone(v) ?? "<null>", `vector ${JSON.stringify(v)}`);
  }
});

test("grants: service_role only; anon/authenticated cannot execute", { skip }, () => {
  for (const fn of ["resolve_msg91_identity_v1(text)", "bind_msg91_pending_profile_v1(text,uuid)", "msg91_canonical_indian_phone_v1(text)"]) {
    const row = q(`select has_function_privilege('anon','public.${fn}','execute'), has_function_privilege('authenticated','public.${fn}','execute'), has_function_privilege('service_role','public.${fn}','execute'), has_function_privilege('public','public.${fn}','execute')`);
    assert.equal(row, "f|f|t|f", fn);
  }
});

test("new phone with no Auth and no public identity resolves to none/absent", { skip }, () => {
  reset();
  const r = resolve("+91 98765 43210");
  assert.equal(r.status, "none");
  assert.equal(r.auth_state, "absent");
});

test("existing user matches by primary, mobile and formatted secondary phone; never by embedded suffix", { skip }, () => {
  reset();
  const a = publicUser({ phone: "+91 98765 43210" });
  assert.deepEqual([resolve("9876543210").status, resolve("9876543210").public_user_id], ["existing", a]);
  reset();
  const b = publicUser({ mobile_number: "09876543210" });
  assert.equal(resolve("919876543210").public_user_id, b);
  reset();
  const c = publicUser({ secondary_phones: "array['00','98765-43210']::text[]" });
  assert.equal(resolve("+919876543210").public_user_id, c);
  reset();
  publicUser({ phone: "9919876543210" }); // embeds the verified number as a suffix of a longer number
  publicUser({ phone: "98765432101" });
  assert.equal(resolve("9876543210").status, "none");
});

test("two public identities for one phone fail closed as duplicate", { skip }, () => {
  reset();
  publicUser({ phone: "9876543210" });
  publicUser({ secondary_phones: "array['+919876543210']::text[]" });
  assert.equal(resolve("9876543210").status, "duplicate_phone_identity");
});

test("company-linked phone without a claimable application is ambiguous; approved unclaimed application is a pending claim", { skip }, () => {
  reset();
  const co = uid();
  q(`insert into public.companies(id,phone) values ('${co}','98765 43210')`);
  publicUser({ company_id: co, phone: "9000000001" });
  assert.equal(resolve("9876543210").status, "ambiguous_phone_identity");
  q(`insert into public.b2b_applications(status,user_id,resolved_company_id,contact_phone) values ('approved',null,'${co}','9876543210')`);
  const r = resolve("9876543210");
  assert.equal(r.status, "none");
  assert.equal(r.approved_b2b_pending_claim, true);
});

test("orphan Auth recovery: exact deterministic email + confirmed matching phone is recoverable", { skip }, () => {
  reset();
  const id = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  const r = resolve("9876543210");
  assert.deepEqual([r.status, r.auth_state, r.auth_user_id], ["none", "orphan_recoverable", id]);
  const id2 = (reset(), authUser({ phone: "+919876543210", email: "919876543210@phone.oasis.local" }));
  assert.equal(resolve("9876543210").auth_user_id, id2);
});

test("takeover guards: unconfirmed, email-only, phone-only or split-identity Auth rows are conflicts", { skip }, () => {
  const em = "919876543210@phone.oasis.local";
  for (const [label, setup] of [
    ["email-only pre-registered", () => authUser({ phone: null, email: em, emailConfirmed: false })],
    ["email-only confirmed but no phone", () => authUser({ phone: null, email: em })],
    ["phone unconfirmed", () => authUser({ phone: "919876543210", email: em, phoneConfirmed: false })],
    ["email unconfirmed", () => authUser({ phone: "919876543210", email: em, emailConfirmed: false })],
    ["phone owned by non-deterministic email", () => authUser({ phone: "919876543210", email: "someone@else.com" })],
    ["email and phone on different Auth users", () => { authUser({ phone: null, email: em }); authUser({ phone: "919876543210", email: "x@y.z" }); }],
  ]) {
    reset();
    setup();
    const r = resolve("9876543210");
    assert.deepEqual([r.status, r.auth_state, r.auth_user_id ?? null], ["none", "conflict", null], label);
  }
});

test("bind creates the PENDING profile atomically, is idempotent, and refuses unsafe states", { skip }, () => {
  reset();
  const id = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  assert.equal(bind("9876543210", id).status, "created");
  assert.equal(q(`select role||'|'||phone from public.users where id='${id}'`), "PENDING|+919876543210");
  assert.equal(bind("9876543210", id).status, "exists"); // retry after lost response
  assert.equal(q("select count(*) from public.users"), "1");
  assert.equal(resolve("9876543210").public_user_id, id);
  // wrong auth id never binds
  reset();
  authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  assert.equal(bind("9876543210", uid()).status, "auth_identity_invalid");
  assert.equal(q("select count(*) from public.users"), "0");
  // a different public identity already owns the phone
  reset();
  const orphan = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  publicUser({ phone: "9876543210" });
  assert.equal(bind("9876543210", orphan).status, "public_identity_conflict");
  assert.equal(q("select count(*) from public.users"), "1");
  // a pre-existing unbound row with the Auth id is not silently adopted
  reset();
  const o2 = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  publicUser({ id: o2, phone: "9000000002" });
  assert.equal(bind("9876543210", o2).status, "public_identity_conflict");
});

test("failed profile write then retry recovers the orphan without duplicate Auth or deletion", { skip }, () => {
  reset();
  const id = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  // simulated failure: profile never written. Retry classification finds the same orphan.
  assert.equal(resolve("9876543210").auth_user_id, id);
  assert.equal(bind("9876543210", id).status, "created");
  assert.equal(q("select count(*) from auth.users"), "1");
});

test("legacy placeholder: resolves to the placeholder, and after reconcile resolves to the new Auth identity", { skip }, () => {
  reset();
  const placeholder = publicUser({ phone: "9876543210", role: "PENDING" });
  q(`insert into public.b2b_applications(status,user_id,contact_phone) values ('pending',null,'9876543210')`);
  const r = resolve("9876543210");
  assert.deepEqual([r.status, r.public_user_id], ["existing", placeholder]); // Edge then reports phone_linked_to_missing_auth_identity
  const insp = q("select eligible||'|'||reason from public.inspect_b2b_pending_phone_placeholder_v1('9876543210')");
  assert.equal(insp, "true|eligible");
  const newAuth = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  q(`select * from public.reconcile_b2b_pending_phone_placeholder_v1('9876543210','${placeholder}','${newAuth}')`);
  const after = resolve("9876543210");
  assert.deepEqual([after.status, after.public_user_id], ["existing", newAuth]);
  assert.equal(q(`select is_active::text||'|'||coalesce(phone,'null') from public.users where id='${placeholder}'`), "false|null");
});

test("concurrency: a resolve blocks behind an in-flight bind and then observes the committed identity", { skip }, async () => {
  reset();
  const id = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  const run = (sql) => new Promise((res, rej) => {
    const t0 = Date.now();
    const p = spawn("psql", [dbUrl(), "-X", "-q", "-At", "-v", "ON_ERROR_STOP=1"]);
    let out = ""; let err = "";
    p.stdout.on("data", (d) => (out += d)); p.stderr.on("data", (d) => (err += d));
    p.on("close", (c) => (c === 0 ? res({ out: out.trim(), ms: Date.now() - t0 }) : rej(new Error(err))));
    p.stdin.end(sql);
  });
  const holder = run(`begin; select public.bind_msg91_pending_profile_v1('9876543210','${id}'); select pg_sleep(1.5); commit;`);
  await new Promise((r) => setTimeout(r, 400));
  const reader = await run("select public.resolve_msg91_identity_v1('9876543210')");
  await holder;
  const seen = JSON.parse(reader.out);
  assert.ok(reader.ms >= 800, `resolve should wait for the lock holder (took ${reader.ms}ms)`);
  assert.deepEqual([seen.status, seen.public_user_id], ["existing", id]);
});

test("concurrency: simultaneous binds of different Auth identities for one phone yield exactly one public identity", { skip }, async () => {
  reset();
  // Two Auth rows cannot both be orphan_recoverable for one phone (unique indexes), so race
  // bind(A) against bind(B) where B is an unrelated Auth user: B must be refused.
  const a = authUser({ phone: "919876543210", email: "919876543210@phone.oasis.local" });
  const b = authUser({ phone: "919999999999", email: "919999999999@phone.oasis.local" });
  const run = (sql) => new Promise((res) => {
    const p = spawn("psql", [dbUrl(), "-X", "-q", "-At"]);
    let out = ""; p.stdout.on("data", (d) => (out += d)); p.on("close", () => res(out.trim())); p.stdin.end(sql);
  });
  const results = await Promise.all([
    run(`select public.bind_msg91_pending_profile_v1('9876543210','${a}')`),
    run(`select public.bind_msg91_pending_profile_v1('9876543210','${b}')`),
    run(`select public.bind_msg91_pending_profile_v1('9876543210','${a}')`),
  ]);
  const statuses = results.map((r) => JSON.parse(r).status).sort();
  assert.equal(statuses.filter((s) => s === "created").length, 1, JSON.stringify(statuses));
  assert.ok(statuses.every((s) => ["created", "exists", "auth_identity_invalid"].includes(s)), JSON.stringify(statuses));
  assert.equal(q("select count(*) from public.users where phone is not null"), "1");
});

test("scale: lookup uses canonical-phone indexes and stays fast with 150k users (no 1000-row ceiling)", { skip }, () => {
  reset();
  q(`insert into public.users(id,role,phone,secondary_phones)
     select gen_random_uuid(),'PENDING','+91'||(7000000000+g)::text, array['+91'||(8000000000+g)::text] from generate_series(1,150000) g;
     insert into auth.users(email,phone,phone_confirmed_at,email_confirmed_at)
     select '91'||(6000000000+g)::text||'@phone.oasis.local','91'||(6000000000+g)::text, now(), now() from generate_series(1,50000) g;
     analyze public.users; analyze auth.users;`);
  const target = publicUser({ phone: "+91 91234 56789" });
  q("analyze public.users");
  const t0 = Date.now();
  const r = resolve("9123456789");
  const ms = Date.now() - t0;
  assert.deepEqual([r.status, r.public_user_id], ["existing", target]);
  // secondary-phone-only match
  const sec = publicUser({ secondary_phones: "array['+91 90000 00001']::text[]" });
  assert.equal(resolve("9000000001").public_user_id, sec);
  // orphan Auth located by indexed email among 50k Auth rows
  assert.equal(resolve("6000000777").auth_user_id, q("select id from auth.users where email='916000000777@phone.oasis.local'"));
  const plan = q(`explain select id from public.users u where public.msg91_canonical_indian_phone_v1(u.phone)='919123456789' or public.msg91_canonical_indian_phone_v1(u.mobile_number)='919123456789' or public.msg91_canonical_phones_v1(u.secondary_phones) @> array['919123456789']`);
  assert.doesNotMatch(plan, /Seq Scan on users/);
  assert.match(plan, /Bitmap Index Scan|Index Scan/);
  assert.ok(ms < 1500, `resolve took ${ms}ms`);
});
