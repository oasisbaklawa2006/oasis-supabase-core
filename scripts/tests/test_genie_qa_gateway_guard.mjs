import {test} from "node:test";
import assert from "node:assert/strict";
import {allowQaBuyerPreflight} from "../genie-qa/qa-gateway-guard.mjs";
const A="919000000001", B="919000000002";
const env={SUPABASE_URL:"https://skhpmltfjgqitntkmclb.supabase.co",QA_MSG91_PROVIDER_ENABLED:"true",QA_MSG91_PROVIDER_AUTH_KEY:"synthetic-test-key",QA_MSG91_TEST_PHONE_ALLOWLIST:A+","+B};
const body={mode:"preflight",channel:"mobile",identifier:A};
const run=(e,b=body)=>allowQaBuyerPreflight(k=>e[k],b);
test("exact QA allowlisted mobile only",()=>{
 assert.equal(run(env),true);
 assert.equal(run(env,{...body,identifier:B}),true);
 for(const b of [{...body,identifier:"919000000003"},{...body,identifier:"+"+A},{...body,channel:"email"},{...body,mode:"send"},{...body,identifier:9},null]) assert.equal(run(env,b),false);
});
test("fail closed on missing flag, wrong project, legacy/AI key, malformed allowlist",()=>{
 for(const patch of [{SUPABASE_URL:"https://other.supabase.co"},{QA_MSG91_PROVIDER_ENABLED:undefined},{QA_MSG91_PROVIDER_ENABLED:"false"},{QA_MSG91_PROVIDER_AUTH_KEY:undefined},{MSG91_AUTH_KEY:"x"},{OPENAI_API_KEY:"x"},{QA_MSG91_TEST_PHONE_ALLOWLIST:A},{QA_MSG91_TEST_PHONE_ALLOWLIST:A+","+A},{QA_MSG91_TEST_PHONE_ALLOWLIST:A+", "+B}]) assert.equal(run({...env,...patch}),false);
});
