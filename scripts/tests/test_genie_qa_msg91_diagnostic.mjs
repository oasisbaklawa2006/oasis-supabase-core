import { execFileSync, spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import { existsSync, mkdtempSync, readFileSync, rmSync, symlinkSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";
import assert from "node:assert/strict";
import {createQaProviderVerifier} from "../genie-qa/qa-msg91-provider-diagnostic-guard.mjs";
import {createQaProviderVerifier as original} from "../genie-qa/qa-msg91-provider-guard.mjs";
import {verifyProviderAccessToken as verifyCanonical} from "../../supabase/functions/msg91-otp/provider-verify.mjs";
import {canonicalIndianPhone} from "../../supabase/functions/msg91-otp/strict-phone-match.mjs";
const a="916000000001", b="916000000002";
const env={SUPABASE_URL:"https://skhpmltfjgqitntkmclb.supabase.co",QA_MSG91_PROVIDER_ENABLED:"true",QA_MSG91_PROVIDER_AUTH_KEY:"synthetic-key",QA_MSG91_TEST_PHONE_ALLOWLIST:a+","+b};
const credentials={authKey:"synthetic-key",accessToken:"synthetic-token"};
const mock=(status,raw)=>async()=>({status,ok:status>=200&&status<300,json:async()=>raw});
const cases=[
 ["verified",{},mock(200,{type:"success",message:a})],
 ["activation_disabled",{QA_MSG91_PROVIDER_ENABLED:"false"},mock(200,{type:"success",message:a})],
 ["allowlist_invalid",{QA_MSG91_TEST_PHONE_ALLOWLIST:a},mock(200,{type:"success",message:a})],
 ["key_invalid",{QA_MSG91_PROVIDER_AUTH_KEY:"different-key"},mock(200,{type:"success",message:a})],
 ["legacy_key_present",{MSG91_AUTH_KEY:"synthetic-legacy"},mock(200,{type:"success",message:a})],
 ["provider_http_auth_rejected",{},mock(401,{type:"error",message:"sensitive-provider-text"})],
 ["provider_http_other_rejected",{},mock(429,{type:"error",message:"sensitive-provider-text"})],
 ["provider_payload_rejected",{},mock(200,{type:"error",message:"sensitive-provider-text"})],
 ["verified_phone_missing_or_invalid",{},mock(200,{type:"success",message:"sensitive-provider-text"})],
 ["verified_phone_conflict",{},mock(200,{type:"success",message:a,data:{phone:b}})],
 ["phone_not_allowlisted",{},mock(200,{type:"success",message:"916000000003"})],
 ["provider_timeout",{},async()=>{throw new DOMException("sensitive-provider-text","TimeoutError")}],
 ["provider_unreachable",{},async()=>{throw new Error("sensitive-provider-text")}],
];
test("diagnostics preserve original decisions and responses and emit only fixed literals",async()=>{
 for(const [code,overrides,fetchImpl] of cases){
  const logs=[];
  const deps={getEnv:n=>({...env,...overrides})[n],verifyCanonical,normalizePhone:canonicalIndianPhone};
  const old=await original(deps)({...credentials,fetchImpl});
  const result=await createQaProviderVerifier({...deps,diagnosticLog:x=>logs.push(x)})({...credentials,fetchImpl});
  assert.deepEqual(result,old,code);
  assert.deepEqual(logs,["GENIE_QA_MSG91_DIAGNOSTIC:"+code]);
 }
});
test("wrong project has no diagnostics and no egress",async()=>{
 let calls=0;const logs=[];
 const v=createQaProviderVerifier({getEnv:n=>({...env,SUPABASE_URL:"https://wrong.supabase.co"})[n],verifyCanonical,normalizePhone:canonicalIndianPhone,diagnosticLog:x=>logs.push(x)});
 assert.equal((await v({...credentials,fetchImpl:async()=>{calls++}})).ok,false);
 assert.equal(calls,0);assert.deepEqual(logs,[]);
});
test("throwing logger cannot change the auth result",async()=>{
 const v=createQaProviderVerifier({getEnv:n=>env[n],verifyCanonical,normalizePhone:canonicalIndianPhone,diagnosticLog:()=>{throw Error("logging failure")}});
 assert.deepEqual(await v({...credentials,fetchImpl:mock(200,{type:"success",message:a})}),{ok:true,raw:{type:"success",message:a}});
});
test("alternate provider destination rejected before egress",async()=>{
 const logs=[];let calls=0;
 const v=createQaProviderVerifier({getEnv:n=>env[n],verifyCanonical:async({fetchImpl})=>{try{await fetchImpl("https://example.invalid",{method:"POST"})}catch{return {ok:false,raw:{}}}},normalizePhone:canonicalIndianPhone,diagnosticLog:x=>logs.push(x)});
 assert.equal((await v({...credentials,fetchImpl:async()=>{calls++}})).ok,false);
 assert.equal(calls,0);assert.deepEqual(logs,["GENIE_QA_MSG91_DIAGNOSTIC:destination_denied"]);
});

const denial = { ok: false, raw: { error: "qa_provider_denied" } };
const success = { ok: true, raw: { type: "success", message: a } };
const diagnostic = code => `GENIE_QA_MSG91_DIAGNOSTIC:${code}`;
const makeVerifier = (diagnosticLog, overrides = {}) => createQaProviderVerifier({
  getEnv: name => env[name],
  verifyCanonical,
  normalizePhone: canonicalIndianPhone,
  diagnosticLog,
  ...overrides,
});

for (const [name, overrides, code] of [
  ["blank token", { accessToken: " \t" }, "token_invalid"],
  ["non-string token", { accessToken: 123 }, "token_invalid"],
  ["token one character over limit", { accessToken: "t".repeat(8193) }, "token_invalid"],
  ["invalid transport", { fetchImpl: null }, "transport_invalid"],
  ["invalid token and transport", { accessToken: "", fetchImpl: null }, "token_invalid"],
]) {
  test(`${name} denies before canonical verification`, async () => {
    const logs = [];
    let calls = 0;
    const verify = makeVerifier(line => logs.push(line), { verifyCanonical: () => { calls++; } });

    assert.deepEqual(await verify({ ...credentials, ...overrides }), denial);
    assert.equal(calls, 0);
    assert.deepEqual(logs, [diagnostic(code)]);
  });
}

test("maximum length token is sent once with redirects disabled and private payload fields omitted", async () => {
  const logs = [];
  const requests = [];
  const accessToken = "t".repeat(8192);
  const result = await makeVerifier(line => logs.push(line))({
    ...credentials,
    accessToken,
    fetchImpl: async (url, init) => {
      requests.push({ url, init });
      return mock(200, {
        type: "success",
        message: "+91 (60000) 00001",
        data: { user: { mobile: a }, private: "sensitive-provider-text" },
      })();
    },
  });

  assert.deepEqual(result, success);
  assert.deepEqual(logs, [diagnostic("verified")]);
  assert.equal(requests.length, 1);
  const [{ url, init }] = requests;
  assert.equal(url, "https://api.msg91.com/api/v5/widget/verifyAccessToken");
  assert.equal(init.method, "POST");
  assert.equal(init.redirect, "error");
  assert.equal(init.headers.authkey, credentials.authKey);
  assert.deepEqual(JSON.parse(init.body), { "access-token": accessToken });
});

for (const [name, fetchImpl, code] of [
  ["403 with a success payload", mock(403, { type: "success", message: a }), "provider_http_auth_rejected"],
  ["redirect with a timeout-shaped payload", mock(302, { error: "provider_timeout" }), "provider_http_other_rejected"],
  ["2xx with a timeout-shaped payload", mock(200, { error: "provider_timeout" }), "provider_payload_rejected"],
  ["2xx with invalid JSON", async () => ({
    status: 200, ok: true, json: async () => { throw new SyntaxError("sensitive JSON"); },
  }), "provider_payload_rejected"],
  ["invalid first phone followed by valid phone", mock(200, {
    type: "success", message: `account:${a}`, data: { phone: a },
  }), "verified_phone_missing_or_invalid"],
  ["valid first phone followed by malformed nested phone", mock(200, {
    type: "success", message: a, data: { user: { mobile: "sensitive-provider-text" } },
  }), "verified_phone_conflict"],
]) {
  test(`${name} emits only ${code} and returns a generic denial`, async () => {
    const logs = [];
    const verify = makeVerifier(line => logs.push(line));
    assert.deepEqual(await verify({ ...credentials, fetchImpl }), denial);
    assert.deepEqual(logs, [diagnostic(code)]);
  });
}

test("unexpected canonical errors leave only a fixed diagnostic and generic denial", async () => {
  const logs = [];
  const verify = makeVerifier(line => logs.push(line), {
    verifyCanonical: async ({ log }) => {
      log({ authKey: credentials.authKey, phone: a });
      throw new Error("sensitive internal error");
    },
  });

  assert.deepEqual(await verify({ ...credentials, fetchImpl: mock(200, {}) }), denial);
  assert.deepEqual(logs, [diagnostic("unexpected_error")]);
});

const root = fileURLToPath(new URL("../../", import.meta.url));
const qaRef = new URL(env.SUPABASE_URL).hostname.split(".")[0];
const stageScript = "scripts/genie-qa/stage_msg91_diagnostic.sh";
const readJson = path => JSON.parse(readFileSync(path, "utf8"));
function scratch(t) {
  const dir = mkdtempSync(join(tmpdir(), "msg91-diagnostic-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

test("diagnostic staging changes only the OTP guard in the certified source closure", t => {
  const destination = join(scratch(t), "candidate");
  execFileSync("bash", [stageScript, qaRef, destination], { cwd: root, timeout: 15_000 });

  const baseline = readJson(join(destination, "msg91-otp-source.json"));
  const candidate = readJson(join(destination, "diagnostic-source.json"));
  const functions = join(destination, "supabase/functions");
  const guardPath = "msg91-otp/qa-msg91-provider-guard.mjs";
  const guard = readFileSync(join(root, "scripts/genie-qa/qa-msg91-provider-diagnostic-guard.mjs"));

  assert.ok(baseline.files.some(file => file.path === guardPath));
  assert.deepEqual(readFileSync(join(functions, guardPath)), guard);
  assert.notEqual(candidate.closureSha256, baseline.closureSha256);
  assert.deepEqual(candidate.files, baseline.files.map(file => file.path === guardPath
    ? { path: guardPath, size: guard.length, sha256: createHash("sha256").update(guard).digest("hex") }
    : file));
  assert.equal(existsSync(join(functions, "msg91-session-bridge")), false);
});

test("diagnostic staging refuses a dangling symlink as the destination", t => {
  const dir = scratch(t);
  const target = join(dir, "must-not-be-created");
  const destination = join(dir, "candidate");
  symlinkSync(target, destination);

  const result = spawnSync("bash", [stageScript, qaRef, destination], { cwd: root, timeout: 15_000 });
  assert.ifError(result.error);
  assert.equal(result.status, 1);
  assert.equal(existsSync(target), false);
});

test("release entry gates deny invalid dispatches before accessing external tools", async t => {
  const dir = scratch(t);
  // Expose dirname for script startup, while keeping all network and mutation tools off PATH.
  symlinkSync("/usr/bin/dirname", join(dir, "dirname"));
  const sha = "a".repeat(40);
  const dispatch = {
    PATH: dir,
    RUNNER_TEMP: dir,
    GITHUB_REPOSITORY: "oasisbaklawa2006/oasis-supabase-core",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    EXPECTED_SHA: sha,
    GITHUB_SHA: sha,
    QA_MODE: "preflight",
    QA_CHANGE_REFERENCE: "Core#495/Buyer#64;QA-EDGE-APPROVAL=test-reference",
    SUPABASE_ACCESS_TOKEN: "synthetic-management-token",
    GH_TOKEN: "synthetic-github-token",
  };
  for (const [name, args, overrides, code] of [
    ["pull request event", ["capture"], { GITHUB_EVENT_NAME: "pull_request" }, "scope"],
    ["non-main branch", ["capture"], { GITHUB_REF: "refs/heads/test" }, "scope"],
    ["mismatched head", ["capture"], { GITHUB_SHA: "b".repeat(40) }, "scope"],
    ["preflight with deploy approval", ["capture"], { QA_APPROVAL: "AUTHORIZE-GENIE-QA-MSG91-DIAGNOSTIC" }, "authorization"],
    ["deploy without approval", ["deploy"], { QA_MODE: "deploy" }, "authorization"],
    ["authorized deploy without rollback evidence", ["deploy"], {
      QA_MODE: "deploy",
      QA_APPROVAL: "AUTHORIZE-GENIE-QA-MSG91-DIAGNOSTIC",
    }, "missing_preflight"],
  ]) {
    await t.test(name, () => {
      const result = spawnSync("/bin/bash", ["scripts/genie-qa/release_msg91_diagnostic.sh", ...args], {
        cwd: root, env: { ...dispatch, ...overrides }, encoding: "utf8", timeout: 5_000,
      });
      assert.ifError(result.error);
      assert.equal(result.status, 1);
      assert.equal(result.stdout, "");
      assert.equal(result.stderr.trim(), `GENIE_QA_DIAGNOSTIC_DENIED: ${code}`);
      assert.equal(existsSync(join(dir, "genie-qa-msg91-diagnostic")), false);
    });
  }
});
