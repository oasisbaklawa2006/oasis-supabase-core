import test from "node:test";
import assert from "node:assert/strict";
import { createQaProviderVerifier } from "../genie-qa/qa-msg91-provider-guard.mjs";
import { verifyProviderAccessToken as verifyCanonical } from "../../supabase/functions/msg91-otp/provider-verify.mjs";
import { canonicalIndianPhone } from "../../supabase/functions/msg91-otp/strict-phone-match.mjs";

// Invented offline fixtures; no numbers, credentials or network used externally.
const a = "916000000001", b = "916000000002";
const env = { SUPABASE_URL: "https://skhpmltfjgqitntkmclb.supabase.co",
  QA_MSG91_PROVIDER_ENABLED: "true", QA_MSG91_PROVIDER_AUTH_KEY: "offline-test-key", QA_MSG91_TEST_PHONE_ALLOWLIST: a + "," + b };
const make = (overrides = {}, canonical = verifyCanonical) => createQaProviderVerifier({
  getEnv: n => ({ ...env, ...overrides })[n], verifyCanonical: canonical, normalizePhone: canonicalIndianPhone
});
const credentials = { authKey: "offline-test-key", accessToken: "offline-test-token" };
const mock = raw => async (url, init) => {
  assert.equal(url, "https://api.msg91.com/api/v5/widget/verifyAccessToken");
  assert.equal(init.redirect, "error"); assert.equal(init.method, "POST");
  return { ok: true, status: 200, json: async () => raw };
};
test("two explicit allowlisted provider-confirmed phones pass with sanitized payload", async () => {
  for (const phone of [a,b]) {
    const r = await make()({ ...credentials, fetchImpl: mock({ type: "success", data: { phone }, ignored: "not returned" }) });
    assert.deepEqual(r, { ok: true, raw: { type: "success", message: phone } });
  }
});
test("wrong target, disabled flag, missing or invalid allowlist, missing credentials deny before network", async () => {
  for (const overrides of [{SUPABASE_URL:"https://tcxvcatsqqertcnycuop.supabase.co"},
    {SUPABASE_URL:undefined},{QA_MSG91_PROVIDER_ENABLED:"false"},{QA_MSG91_TEST_PHONE_ALLOWLIST:undefined},
    {QA_MSG91_TEST_PHONE_ALLOWLIST:a},{QA_MSG91_TEST_PHONE_ALLOWLIST:a+","+a},
    {QA_MSG91_PROVIDER_AUTH_KEY:undefined},{QA_MSG91_PROVIDER_AUTH_KEY:"different-key"},
    {QA_MSG91_PROVIDER_AUTH_KEY:" offline-test-key"},{MSG91_AUTH_KEY:"legacy-key"}]) {
    let called = false;
    const r = await make(overrides)({...credentials, fetchImpl:async()=>{called=true;}});
    assert.equal(r.ok,false); assert.equal(called,false);
  }
  for (const bad of [{authKey:""},{accessToken:""},{accessToken:"x".repeat(8193)}]) {
    let called=false;
    assert.equal((await make()({...credentials,...bad,fetchImpl:async()=>{called=true;}})).ok,false);
    assert.equal(called,false);
  }
});
test("malformed, unapproved, conflicting and rejected provider results deny", async () => {
  for (const raw of [{type:"success",message:"916000000003"},
    {type:"success",message:a,data:{phone:b}},{type:"success",message:a,data:{phone:"malformed"}},
    {type:"success",message:"abc"+a},{type:"success"},
    {type:"error",message:a},{type:"success",message:"000"+a},null]) {
    const r = await make()({...credentials,fetchImpl:mock(raw)});
    assert.deepEqual(r,{ok:false,raw:{error:"qa_provider_denied"}});
  }
  for (const fetchImpl of [async()=>{throw Error("offline")},async()=>({ok:false,status:401,json:async()=>({type:"success",message:a})})]) {
    assert.equal((await make()({...credentials,fetchImpl})).ok,false);
  }
});
test("alternate canonical network destination is rejected before fetch", async () => {
  const other = async ({fetchImpl}) => fetchImpl("https://example.invalid",{method:"POST"});
  let called=false;
  assert.equal((await make({},other)({...credentials,fetchImpl:async()=>{called=true;}})).ok,false);
  assert.equal(called,false);
});

test("provider receives only dedicated QA credential and redirect-safe request", async () => {
  let observed = 0;
  const r = await make()({...credentials, fetchImpl: async (url, init) => {
    observed++;
    assert.equal(init.headers.authkey, "offline-test-key");
    assert.equal(init.redirect, "error");
    return mock({type:"success",message:a})(url, init);
  }});
  assert.equal(observed, 1);
  assert.equal(r.ok, true);
});
