// Provider verification (success, failure, timeout, retry) and production dependency wiring.
import assert from "node:assert/strict";
import { test } from "node:test";
import { verifyProviderAccessToken, MSG91_VERIFY_URL } from "../functions/msg91-otp/provider-verify.mjs";
import { createExchangeDeps, mintMagicTokenHash } from "../functions/msg91-otp/exchange-deps.mjs";
import { exchangeVerifiedPhone } from "../functions/msg91-otp/identity-flow.mjs";

const json = (status, body) => ({ ok: status >= 200 && status < 300, status, json: async () => body });

test("provider success requires HTTP ok AND type=success; secrets never appear in logs", async () => {
  const logs = [];
  let seen;
  const fetchImpl = async (url, init) => { seen = { url, init }; return json(200, { type: "success", message: "919876543210" }); };
  const r = await verifyProviderAccessToken({ authKey: "SECRET_AUTHKEY", accessToken: "TOKEN123", fetchImpl, log: (e) => logs.push(e) });
  assert.equal(r.ok, true);
  assert.equal(seen.url, MSG91_VERIFY_URL);
  assert.equal(seen.url, "https://api.msg91.com/api/v5/widget/verifyAccessToken");
  assert.equal(seen.init.headers.authkey, "SECRET_AUTHKEY");
  assert.deepEqual(JSON.parse(seen.init.body), { "access-token": "TOKEN123" });
  assert.equal(Object.hasOwn(JSON.parse(seen.init.body), "authkey"), false);
  assert.ok(seen.init.signal instanceof AbortSignal, "an abort signal bounds the provider call");
  assert.doesNotMatch(JSON.stringify(logs), /SECRET_AUTHKEY|TOKEN123|919876543210/);
});

test("provider failures all fail closed: non-success type, 4xx/5xx, non-JSON, array body, missing key", async () => {
  for (const [label, fetchImpl] of [
    ["type=error", async () => json(200, { type: "error", message: "invalid token" })],
    ["http 401 with success body", async () => json(401, { type: "success" })],
    ["http 500", async () => json(500, {})],
    ["non-JSON body", async () => ({ ok: true, status: 200, json: async () => { throw new SyntaxError("x"); } })],
    ["array body", async () => json(200, ["success"])],
    ["network error", async () => { throw new TypeError("fetch failed"); }],
  ]) {
    const r = await verifyProviderAccessToken({ authKey: "k", accessToken: "t", fetchImpl });
    assert.equal(r.ok, false, label);
  }
  const noKey = await verifyProviderAccessToken({ authKey: "", accessToken: "t", fetchImpl: async () => { throw new Error("must not be called"); } });
  assert.deepEqual([noKey.ok, noKey.raw.error], [false, "auth_key_unavailable"]);
});

test("a hung provider is aborted by the timeout and reported as provider_timeout", async () => {
  const fetchImpl = (_url, init) => new Promise((_res, rej) => init.signal.addEventListener("abort", () => rej(init.signal.reason)));
  const t0 = Date.now();
  // AbortSignal.timeout timers are unref'd in Node; a real in-flight socket keeps the loop alive.
  const keepAlive = setTimeout(() => {}, 5000);
  const r = await verifyProviderAccessToken({ authKey: "k", accessToken: "t", fetchImpl, timeoutMs: 80 });
  clearTimeout(keepAlive);
  assert.deepEqual([r.ok, r.raw.error], [false, "provider_timeout"]);
  assert.ok(Date.now() - t0 < 2000);
});

test("provider retry: a failed verification followed by a valid one succeeds independently (no state carried)", async () => {
  let n = 0;
  const fetchImpl = async () => (n++ === 0 ? json(503, {}) : json(200, { type: "success" }));
  assert.equal((await verifyProviderAccessToken({ authKey: "k", accessToken: "t", fetchImpl })).ok, false);
  assert.equal((await verifyProviderAccessToken({ authKey: "k", accessToken: "t", fetchImpl })).ok, true);
});

test("token mint: hashed_token preferred, action_link fallback, every failure shape fails closed", async () => {
  const admin = (impl) => ({ auth: { admin: { generateLink: impl } } });
  assert.deepEqual(await mintMagicTokenHash(admin(async () => ({ data: { properties: { hashed_token: "H" } }, error: null })), "e"), { tokenHash: "H" });
  assert.deepEqual(await mintMagicTokenHash(admin(async () => ({ data: { properties: { action_link: "https://x/verify?token_hash=A%2BB&type=magiclink" } }, error: null })), "e"), { tokenHash: "A+B" });
  for (const impl of [async () => ({ data: null, error: { message: "boom" } }), async () => ({ data: { properties: {} }, error: null }), async () => { throw new Error("net"); }]) {
    assert.deepEqual(await mintMagicTokenHash(admin(impl), "e"), { error: "session_token_mint_failed" });
  }
  assert.deepEqual(await mintMagicTokenHash(null, "e"), { error: "session_token_mint_failed" });
});

test("createExchangeDeps wires exactly the service_role admin calls and the flow runs end to end over it", async () => {
  const calls = [];
  const P = "919876543210";
  const admin = {
    rpc: async (name, args) => { calls.push(["rpc", name]); return name === "resolve_msg91_identity_v1"
      ? { data: { status: "none", auth_state: "absent", approved_b2b_pending_claim: false }, error: null }
      : { data: { status: "created" }, error: null }; },
    auth: { admin: {
      createUser: async (attrs) => {
        const proof = attrs.app_metadata.msg91_verified_phone_alias;
        assert.equal(proof.email, attrs.email);
        assert.match(proof.nonce, /^[0-9a-f-]{36}$/);
        calls.push(["createUser", attrs.phone, attrs.email, attrs.phone_confirm, attrs.email_confirm]);
        return { data: { user: { id: "new-1" } }, error: null };
      },
      getUserById: async () => { throw new Error("not used"); },
      updateUserById: async () => { throw new Error("not used"); },
      generateLink: async (a) => { calls.push(["generateLink", a.type, a.email]); return { data: { properties: { hashed_token: "HT" } }, error: null }; },
    } },
  };
  const deps = createExchangeDeps(admin, () => {});
  const r = await exchangeVerifiedPhone(deps, P);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { ok: true, type: "success", user_id: "new-1", email: `${P}@phone.oasis.local`, phone: `+${P}`, is_new: true, approved_b2b_pending_claim: false, token_hash: "HT" });
  assert.deepEqual(calls, [
    ["rpc", "resolve_msg91_identity_v1"],
    ["createUser", `+${P}`, `${P}@phone.oasis.local`, true, true],
    ["rpc", "bind_msg91_pending_profile_v1"],
    ["generateLink", "magiclink", `${P}@phone.oasis.local`],
  ]);
});

test("binding an internal email supplies a fresh authorization through the Auth admin API", async () => {
  const writes = [];
  const deps = createExchangeDeps({
    auth: { admin: {
      updateUserById: async (id, attrs) => {
        writes.push({ id, attrs });
        return { error: null };
      },
    } },
  });
  const email = "919876543210@phone.oasis.local";
  await deps.bindInternalEmail("existing-user", email);
  await deps.bindInternalEmail("existing-user", email);
  for (const { id, attrs } of writes) {
    assert.equal(id, "existing-user");
    assert.equal(attrs.email, email);
    assert.equal(attrs.email_confirm, true);
    assert.equal(attrs.app_metadata.msg91_verified_phone_alias.email, email);
  }
  assert.notEqual(
    writes[0].attrs.app_metadata.msg91_verified_phone_alias.nonce,
    writes[1].attrs.app_metadata.msg91_verified_phone_alias.nonce,
  );
});
