// Scratch-only Edge bundle. Never deploy this file through canonical function lanes.
// The runner substitutes only fixed, validated literals and the hash-pinned classifier.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { verifyProviderAccessToken } from "./provider-verify.mjs";

const QA_URL = "https://skhpmltfjgqitntkmclb.supabase.co";
const PROOF_SHA = "__PROOF_SHA__";
const RUN = "__RUN_ID__";
const EXPIRY = __EXPIRES_MS__;
const CLEANUP_EXPIRY = EXPIRY + 8 * 60 * 1000;
const EMAIL = "genie-qa-transport-" + RUN + "@example.invalid";
const COMPANY = "a6150000-0000-4000-8000-000000000001";
const LINE = "c56f3d9e-58a4-4e97-a3c9-c434ef6037e2";
const PRODUCT = "a6182000-0000-4000-8000-000000000003";
const WRONG_PRODUCT = "00000000-0000-4000-8000-000000000000";
const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
function projectOnly() { return Deno.env.get("SUPABASE_URL") === QA_URL; }
function isolated() {
  return projectOnly() &&
    Deno.env.get("QA_MSG91_PROVIDER_ENABLED") === undefined &&
    Deno.env.get("OPENAI_API_KEY") === undefined &&
    Deno.env.get("MSG91_AUTH_KEY") === undefined;
}
// The SDK may pass strings or URL objects. Refuse opaque Request objects
// instead of forwarding their inherited headers, body or redirect policy.
const boundedFetch: typeof fetch = (input, init) => {
  if (input instanceof Request) throw Error("QA_HTTP_REQUEST_DENIED");
  const candidate = new URL(input);
  const path = candidate.pathname;
  const fixedPaths = [
    "/auth/v1/admin/users", "/auth/v1/token", "/auth/v1/logout",
    "/rest/v1/users", "/rest/v1/profiles", "/rest/v1/b2b_applications",
    "/rest/v1/customer_order_draft_lines", "/rest/v1/customer_order_drafts",
    "/rest/v1/products", "/rest/v1/rpc/customer_buyer_eligible_company_id",
    "/rest/v1/rpc/update_customer_order_draft_line_genie_if_quantity_v1",
  ];
  const adminUser = /^\/auth\/v1\/admin\/users\/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(path);
  if (candidate.origin !== QA_URL || candidate.username || candidate.password || candidate.hash)
    throw Error("QA_HTTP_TARGET_DENIED");
  // The candidate query is already a parsed URL search component; attaching
  // it to a known path cannot change its scheme, host, port, or pathname.
  // Require exact membership in the full-URL allowlist at the fetch boundary.
  const approvedPaths = adminUser ? [...fixedPaths, path] : fixedPaths;
  const allowedUrls = approvedPaths.map(approvedPath => {
    const target = new URL(QA_URL);
    target.pathname = approvedPath;
    target.search = candidate.search;
    return target.href;
  });
  const url = candidate.href;
  if (allowedUrls.includes(url)) {
    return fetch(url, { ...init, redirect: "error", signal: AbortSignal.timeout(10000) });
  }
  throw Error("QA_HTTP_TARGET_DENIED");
};
const clientOptions = { auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  global: { fetch: boundedFetch } };
const admin = projectOnly() && serviceKey ? createClient(QA_URL, serviceKey, clientOptions) : null;
type Channel = "mobile" | "email";
type EligibilityState = "approved" | "pending" | "employee" | "rejected" | "unknown" | "ambiguous";
type Eligibility = { state: EligibilityState; allowOtp: boolean; message: string };
// __CANONICAL_CLASSIFIER__

function output(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), {status, headers: {"Content-Type": "application/json", "Cache-Control": "no-store"}});
}
function check(ok: unknown) { if (!ok) throw Error("QA_PROBE_STOP"); }
function safeUid(uid: unknown): uid is string {
  return typeof uid === "string" && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(uid);
}
async function allowed(req: Request) {
  if (!projectOnly() || !admin || Date.now() >= CLEANUP_EXPIRY || req.method !== "POST") return false;
  const proof = req.headers.get("x-genie-qa-proof") || "";
  if (!/^[0-9a-f]{64}$/.test(proof)) return false;
  const bytes = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(proof)));
  const expected = PROOF_SHA.match(/../g) || [];
  let diff = 0;
  for (let i=0; i<32; i++) diff |= bytes[i] ^ Number.parseInt(expected[i], 16);
  return diff === 0 && Date.now() < CLEANUP_EXPIRY;
}
async function cleanup(uid: string, accessToken?: string) {
  check(admin && safeUid(uid) && projectOnly() && Date.now() < CLEANUP_EXPIRY);
  const existing = await admin!.auth.admin.getUserById(uid);
  // Never delete an arbitrary caller-supplied identity.
  check(!existing.error && existing.data.user?.email === EMAIL &&
    existing.data.user.app_metadata?.genie_qa_transport_run === RUN);
  // Remove buyer authority before session revocation, so even an unexpired
  // stateless access token cannot retain approved buyer access.
  const profile = await admin!.from("profiles").delete().eq("id", uid);
  const logout = accessToken ? await admin!.auth.admin.signOut(accessToken, "global") : null;
  const user = await admin!.from("users").delete().eq("id", uid).eq("email", EMAIL);
  const removed = await admin!.auth.admin.deleteUser(uid, false);
  check(!profile.error && !logout?.error && !user.error && !removed.error);
}
async function cartProbe(publicKey: string) {
  check(admin && isolated());
  // Direct privileged read only; get_customer_order_draft_v1 can create a cart
  // if none exists, so the diagnostic intentionally does not call that RPC.
  const line = await admin!.from("customer_order_draft_lines").select("id,product_id,quantity,draft_id").eq("id", LINE).single();
  check(!line.error && line.data?.id === LINE && line.data?.product_id === PRODUCT && Number(line.data?.quantity) === 18);
  const draft = await admin!.from("customer_order_drafts").select("id,company_id,status,readiness_status").eq("id", line.data!.draft_id).single();
  check(!draft.error && draft.data?.company_id === COMPANY && draft.data?.status === "active" && draft.data?.readiness_status === "ready");
  const sentinel = await admin!.from("products").select("id").eq("id", WRONG_PRODUCT).limit(1);
  check(!sentinel.error && sentinel.data?.length === 0);
  let uid: string | undefined;
  let accessToken: string | undefined;
  try {
    // Real GoTrue session, never sign a JWT manually and never use Buyer A/B credentials.
    // The temporary principal has only a buyer profile in the already-synthetic
    // company. No company insert (which would create financial opening evidence).
    const password = crypto.randomUUID() + crypto.randomUUID() + "aA1!";
    check(isolated() && Date.now() < EXPIRY);
    const created = await admin!.auth.admin.createUser({email: EMAIL, password, email_confirm: true,
      app_metadata: {genie_qa_transport_run: RUN}});
    const user = created.data?.user;
    check(!created.error && user?.email === EMAIL && safeUid(user?.id) &&
      user?.app_metadata?.genie_qa_transport_run === RUN);
    uid = user!.id;
    check(isolated() && Date.now() < EXPIRY);
    const profile = await admin!.from("profiles").insert({id: uid, role: "B2B_BUYER",
      status: "approved", is_approved: true, company_id: COMPANY, price_tier: "B2B", email: EMAIL});
    check(!profile.error);
    const client = createClient(QA_URL, publicKey, clientOptions);
    check(isolated() && Date.now() < EXPIRY);
    const signed = await client.auth.signInWithPassword({email: EMAIL, password});
    check(!signed.error && signed.data.user?.id === uid && signed.data.session?.access_token);
    accessToken = signed.data.session!.access_token;
    check(Number(signed.data.session!.expires_in) > 0 && Number(signed.data.session!.expires_in) <= 3600);
    const headers = {"apikey": publicKey, "Authorization": "Bearer " + accessToken, "Content-Type": "application/json"};
    const authority = await boundedFetch(QA_URL + "/rest/v1/rpc/customer_buyer_eligible_company_id", {method:"POST", headers, body:"{}"});
    check(authority.status === 200 && await authority.json() === COMPANY);
    check(isolated() && Date.now() < EXPIRY);
    // Actual PostgREST HTTP status, not a simulated SQL exception or Edge mapping.
    // Nonexistent product UUID cannot equal the FK-backed line's product.
    const res = await boundedFetch(QA_URL + "/rest/v1/rpc/update_customer_order_draft_line_genie_if_quantity_v1", {
      method:"POST", headers, body:JSON.stringify({p_line_id:LINE,p_product_id:WRONG_PRODUCT,p_expected_quantity:19,p_quantity:18})});
    const body = await res.json();
    check(res.status === 409 && body?.code === "PT409" && typeof body.message === "string" &&
      body.message.includes("GENIE_CART_STALE"));
  } finally {
    if (uid) await cleanup(uid, accessToken);
  }
  return output(409, {ok:false, code:"PT409", upstream_status:409, synthetic_session:true, cleanup_complete:true});
}
async function providerProbe() {
  const key = Deno.env.get("QA_MSG91_PROVIDER_AUTH_KEY") || "";
  check(isolated() && Date.now() < EXPIRY && key && key === key.trim());
  let observed = false;
  let status = 0;
  const result = await verifyProviderAccessToken({
    authKey:key, accessToken:"genie-qa-invalid-" + RUN,
    fetchImpl: async (url, init) => {
      check(isolated() && Date.now() < EXPIRY && !observed && url === "https://api.msg91.com/api/v5/widget/verifyAccessToken" && init?.method === "POST");
      observed = true;
      // The verification destination is literal; the canonical verifier's
      // URL is checked above but is never forwarded into the HTTP client.
      const response = await fetch("https://api.msg91.com/api/v5/widget/verifyAccessToken", {
        ...init, redirect: "error", signal: AbortSignal.timeout(10000),
      });
      status = response.status;
      return response;
    }, log: () => {},
  });
  // MSG91 documents semantic denial even when upstream HTTP is 200. Require
  // explicit invalid-token text, not auth-key failure, timeout, 429 or 5xx.
  const raw = result.raw as Record<string, unknown>;
  const message = typeof raw?.message === "string" ? raw.message.toLowerCase().replace(/[^a-z]/g,"") : "";
  check(observed && [200,400,401,403].includes(status) && result.ok === false &&
    raw?.type === "error" && ["invalidaccesstoken","invalidtoken"].includes(message));
  return output(401, {ok:false,error:"provider_verification_failed",provider_reached:true,provider_invalid_token:true,upstream_status:status});
}
const seen = new Set<string>();
Deno.serve(async (req) => {
  try {
    if (!await allowed(req)) return output(403,{ok:false,error:"scope_denied"});
    const body = await req.json();
    if (!body || typeof body !== "object" || Array.isArray(body)) return output(400,{ok:false,error:"invalid_request"});
    const action = body.action;
    if (action === "cleanup") {
      if (Date.now() >= CLEANUP_EXPIRY) return output(403,{ok:false,error:"scope_denied"});
      if (Object.keys(body).length !== 2 || !safeUid(body.uid)) return output(400,{ok:false,error:"invalid_request"});
      await cleanup(body.uid);
      return output(200,{ok:true,cleanup_complete:true});
    }
    if (!isolated() || Date.now() >= EXPIRY) return output(403,{ok:false,error:"scope_denied"});
    if (Object.keys(body).length !== 1 || !["rejected","staff","provider","pt409"].includes(action) || seen.has(action))
      return output(400,{ok:false,error:"invalid_request"});
    seen.add(action);
    if (action === "provider") return await providerProbe();
    if (action === "pt409") {
      const publicKey = req.headers.get("apikey") || "";
      check(/^sb_publishable_[A-Za-z0-9_-]+$/.test(publicKey));
      return await cartProbe(publicKey);
    }
    const eligibility = await classifyMobile(action === "rejected" ? "910000000001" : "910000000002");
    check(eligibility.state === (action === "rejected" ? "rejected" : "employee") && eligibility.allowOtp === false);
    return output(200,{ok:true,state:eligibility.state,allowOtp:false});
  } catch {
    // No raw errors, tokens, identity details or provider responses.
    return output(500,{ok:false,error:"probe_failed"});
  }
});
