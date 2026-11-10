// Behavioural tests for the provider-verified exchange orchestration (identity-flow.mjs)
// against an in-memory model that enforces the same guarantees as the DB authority:
// serialised resolve/bind per phone and unique Auth email/phone. Real SQL behaviour is covered
// in msg91_identity_authority.test.mjs; these tests cover the Edge-side decisions.
import assert from "node:assert/strict";
import { test } from "node:test";
import { exchangeVerifiedPhone } from "../functions/msg91-otp/identity-flow.mjs";

const P = "919876543210";
const EMAIL = `${P}@phone.oasis.local`;
const tick = () => new Promise((r) => setImmediate(r));

function world({ auth = [], pub = [], failCreate = false, failBindOnce = false, failMint = false, rpcDown = false, authLookupError = null } = {}) {
  const w = { auth: [...auth], pub: [...pub], creates: 0, deletes: 0, mints: [], emailBinds: [] };
  let lock = Promise.resolve();
  const serial = (fn) => { const run = lock.then(fn); lock = run.catch(() => {}); return run; };
  let bindFailures = failBindOnce ? 1 : 0;
  const classify = () => {
    const matches = w.pub.filter((u) => u.phone === `+${P}`);
    if (matches.length > 1) return { status: "duplicate_phone_identity" };
    if (matches.length === 1) {
      const owner = w.auth.find((a) => a.email === EMAIL);
      return { status: "existing", public_user_id: matches[0].id, approved_b2b_pending_claim: false, auth_internal_email_user_id: owner?.id ?? null };
    }
    const byEmail = w.auth.find((a) => a.email === EMAIL);
    const byPhone = w.auth.find((a) => a.phone === P);
    if (!byEmail && !byPhone) return { status: "none", auth_state: "absent", approved_b2b_pending_claim: false };
    if (byEmail && byEmail === byPhone && byEmail.confirmed) return { status: "none", auth_state: "orphan_recoverable", auth_user_id: byEmail.id, approved_b2b_pending_claim: false };
    return { status: "none", auth_state: "conflict", approved_b2b_pending_claim: false };
  };
  w.deps = {
    rpc: (name, args) => serial(async () => {
      await tick();
      if (rpcDown) return { data: null, error: { message: "down" } };
      if (name === "resolve_msg91_identity_v1") return { data: classify(), error: null };
      if (name === "bind_msg91_pending_profile_v1") {
        if (bindFailures-- > 0) return { data: null, error: { message: "transport" } };
        const r = classify();
        if (r.status === "existing") return { data: { status: r.public_user_id === args.p_auth_user_id ? "exists" : "public_identity_conflict" }, error: null };
        if (r.status !== "none" || r.auth_user_id !== args.p_auth_user_id) return { data: { status: "auth_identity_invalid" }, error: null };
        w.pub.push({ id: args.p_auth_user_id, phone: `+${P}`, role: "PENDING" });
        return { data: { status: "created" }, error: null };
      }
      throw new Error(`unexpected rpc ${name}`);
    }),
    getAuthUserById: async (id) => {
      await tick();
      if (authLookupError) return { data: null, error: authLookupError };
      const u = w.auth.find((a) => a.id === id);
      return u ? { data: { user: { id: u.id, email: u.email } }, error: null } : { data: null, error: { status: 404 } };
    },
    createAuthUser: async (attrs) => {
      await tick();
      w.creates++;
      if (failCreate) return { data: null, error: { code: "unexpected" } };
      if (w.auth.some((a) => a.email === attrs.email || a.phone === attrs.phone.slice(1))) return { data: null, error: { code: "email_exists" } };
      const u = { id: `auth-${w.auth.length + 1}`, email: attrs.email, phone: attrs.phone.slice(1), confirmed: true };
      w.auth.push(u);
      return { data: { user: u }, error: null };
    },
    bindInternalEmail: async (id, email) => { const u = w.auth.find((a) => a.id === id); u.email = email; w.emailBinds.push(id); return { error: null }; },
    mintTokenHash: async (email) => { if (failMint) return { error: "session_token_mint_failed" }; w.mints.push(email); return { tokenHash: `th-${email}` }; },
    log: () => {},
  };
  return w;
}

test("successful widget exchange for a brand-new phone creates one Auth user and one PENDING profile", async () => {
  const w = world();
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.ok, r.body.is_new, r.body.phone, r.body.email, r.body.token_hash], [true, true, `+${P}`, EMAIL, `th-${EMAIL}`]);
  assert.equal(w.auth.length, 1); assert.equal(w.pub.length, 1); assert.equal(w.deletes, 0);
});

test("existing user logs in without creating anything (email already bound)", async () => {
  const w = world({ auth: [{ id: "u1", email: "u1@x.com", phone: P, confirmed: true }], pub: [{ id: "u1", phone: `+${P}`, role: "B2B_BUYER" }] });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.user_id, r.body.email, r.body.is_new], ["u1", "u1@x.com", false]);
  assert.equal(w.creates, 0);
});

test("existing user without an Auth email gets the deterministic internal email bound", async () => {
  const w = world({ auth: [{ id: "u1", email: "", phone: P, confirmed: true }], pub: [{ id: "u1", phone: `+${P}` }] });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.equal(r.status, 200);
  assert.equal(r.body.email, EMAIL);
  assert.deepEqual(w.emailBinds, ["u1"]);
});

test("legacy placeholder without an Auth user yields the bridge recovery signal (409), not a creation", async () => {
  const w = world({ pub: [{ id: "ph", phone: `+${P}`, role: "PENDING" }] });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.error], [409, "phone_linked_to_missing_auth_identity"]);
  assert.equal(w.creates, 0);
  assert.equal(w.mints.length, 0);
});

test("Auth lookup transport/permission errors fail closed as identity_lookup_failed (500)", async () => {
  const w = world({ pub: [{ id: "ph", phone: `+${P}` }], authLookupError: { status: 500 } });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.error], [500, "identity_lookup_failed"]);
});

test("orphan Auth user (profile write previously failed) is recovered on retry: no duplicate create, no delete", async () => {
  const w = world({ auth: [{ id: "orph", email: EMAIL, phone: P, confirmed: true }] });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.equal(r.status, 200);
  assert.deepEqual([r.body.user_id, r.body.is_new], ["orph", true]);
  assert.equal(w.creates, 0); assert.equal(w.deletes, 0); assert.equal(w.pub.length, 1);
});

test("profile bind failure after Auth creation fails the request, and the retry completes via orphan recovery", async () => {
  const w = world({ failBindOnce: true });
  const first = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([first.status, first.body.error], [500, "pending_profile_create_failed"]);
  assert.equal(w.auth.length, 1); assert.equal(w.pub.length, 0); assert.equal(w.mints.length, 0);
  const second = await exchangeVerifiedPhone(w.deps, P);
  assert.equal(second.status, 200);
  assert.equal(w.auth.length, 1); assert.equal(w.pub.length, 1); assert.equal(w.creates, 1);
});

test("lost-response retry: profile committed, then re-login is an ordinary existing login", async () => {
  const w = world({ auth: [{ id: "a1", email: EMAIL, phone: P, confirmed: true }], pub: [{ id: "a1", phone: `+${P}`, role: "PENDING" }] });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.user_id, r.body.is_new], [200, "a1", false]);
});

test("collisions fail closed without minting a session", async () => {
  const cases = [
    ["Auth email owned by an unconfirmed/foreign identity", world({ auth: [{ id: "x", email: EMAIL, phone: null, confirmed: false }] }), 409, "auth_recovery_identity_conflict"],
    ["phone owned by a non-deterministic-email Auth user", world({ auth: [{ id: "x", email: "a@b.c", phone: P, confirmed: true }] }), 409, "auth_recovery_identity_conflict"],
    ["internal email held by a different Auth user than the public match", world({ auth: [{ id: "other", email: EMAIL, phone: null, confirmed: true }, { id: "u1", email: "u1@x", phone: P, confirmed: true }], pub: [{ id: "u1", phone: `+${P}` }] }), 409, "auth_recovery_identity_conflict"],
    ["two public identities", world({ pub: [{ id: "a", phone: `+${P}` }, { id: "b", phone: `+${P}` }] }), 409, "duplicate_phone_identity"],
    ["identity authority unavailable", world({ rpcDown: true }), 500, "identity_lookup_failed"],
  ];
  for (const [label, w, status, error] of cases) {
    const r = await exchangeVerifiedPhone(w.deps, P);
    assert.deepEqual([r.status, r.body.error], [status, error], label);
    assert.equal(w.mints.length, 0, label);
    assert.equal(w.deletes, 0, label);
  }
});

test("Auth creation failure with no concurrent winner returns auth_user_create_failed and creates no profile", async () => {
  const w = world({ failCreate: true });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.error], [500, "auth_user_create_failed"]);
  assert.equal(w.pub.length, 0);
});

test("token mint failure is reported as 502 and never leaks provider detail", async () => {
  const w = world({ failMint: true });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.error], [502, "session_token_mint_failed"]);
});

test("concurrent requests for the same new phone converge on one Auth user and one profile", async () => {
  for (let round = 0; round < 25; round++) {
    const w = world();
    const results = await Promise.all(Array.from({ length: 8 }, () => exchangeVerifiedPhone(w.deps, P)));
    assert.ok(results.every((r) => r.status === 200), JSON.stringify(results.map((r) => r.body.error)));
    assert.equal(new Set(results.map((r) => r.body.user_id)).size, 1);
    assert.equal(w.auth.length, 1, "exactly one Auth identity");
    assert.equal(w.pub.length, 1, "exactly one public identity");
    assert.equal(w.deletes, 0);
    assert.equal(results.filter((r) => r.body.is_new).length >= 1, true);
  }
});

test("a transient Auth conflict from a concurrent create settles on re-resolve; a stable conflict still fails closed", async () => {
  // transient: first classification sees a half-created identity, second sees it recoverable
  const w = world();
  const real = w.deps.rpc;
  let calls = 0;
  w.deps.sleep = async () => {};
  w.deps.rpc = async (name, args) => {
    if (name === "resolve_msg91_identity_v1" && calls++ === 0) {
      w.auth.push({ id: "mid", email: EMAIL, phone: P, confirmed: true });
      return { data: { status: "none", auth_state: "conflict", approved_b2b_pending_claim: false }, error: null };
    }
    return real(name, args);
  };
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.user_id, w.creates], [200, "mid", 0]);
  // stable: foreign identity holds the deterministic email; the retry still reports a conflict
  const s = world({ auth: [{ id: "x", email: EMAIL, phone: null, confirmed: false }] });
  let slept = 0;
  s.deps.sleep = async () => { slept++; };
  const f = await exchangeVerifiedPhone(s.deps, P);
  assert.deepEqual([f.status, f.body.error, slept, s.mints.length, s.creates], [409, "auth_recovery_identity_conflict", 1, 0, 0]);
});

test("conflicting Auth phone ownership fails closed for an existing public identity (no session)", async () => {
  // Public identity u1 matches the phone, but a DIFFERENT Auth user owns the verified phone number.
  const w = world({ auth: [{ id: "u1", email: "u1@x.com", phone: null, confirmed: true }, { id: "other", email: "o@x.com", phone: P, confirmed: true }], pub: [{ id: "u1", phone: `+${P}` }] });
  const base = w.deps.rpc;
  w.deps.rpc = async (name, args) => {
    const r = await base(name, args);
    if (name === "resolve_msg91_identity_v1" && r.data?.status === "existing") r.data.auth_phone_user_id = "other";
    return r;
  };
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.error, w.mints.length], [409, "auth_recovery_identity_conflict", 0]);
});

test("an Auth lookup that returns a different user than the matched public identity fails closed", async () => {
  const w = world({ pub: [{ id: "u1", phone: `+${P}` }] });
  w.deps.getAuthUserById = async () => ({ data: { user: { id: "someone-else", email: "s@x.com" } }, error: null });
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.error, w.mints.length], [409, "auth_recovery_identity_conflict", 0]);
});

test("approved_b2b_pending_claim from the database is preserved on the success body", async () => {
  const w = world({ auth: [{ id: "u1", email: "u1@x.com", phone: P, confirmed: true }], pub: [{ id: "u1", phone: `+${P}` }] });
  const base = w.deps.rpc;
  w.deps.rpc = async (name, args) => { const r = await base(name, args); if (r.data?.status === "existing") r.data.approved_b2b_pending_claim = true; return r; };
  const r = await exchangeVerifiedPhone(w.deps, P);
  assert.deepEqual([r.status, r.body.approved_b2b_pending_claim], [200, true]);
});
