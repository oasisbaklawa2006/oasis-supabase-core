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
