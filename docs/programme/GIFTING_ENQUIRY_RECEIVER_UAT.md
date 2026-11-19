# Gifting enquiry receiver — synthetic UAT record (Central #677, Core PR #557)

All data below is synthetic (`*@example.invalid`, source `uat-synthetic-pr557` / `e2e-synthetic`). No production
project, data or credential was touched. No token value appears in this document, in logs or in chat.

## 1. Isolated target and its lifetime

| Item | Evidence (19 Nov 2026) |
|---|---|
| Target | Supabase preview branch `htqvalootmxurzbczxek` of Core PR #557 (parent project `tcxvcatsqqertcnycuop`) |
| Lifetime | `persistent:false`, created by the PR's Supabase integration; it exists only while PR #557 exists (removed on close/merge, may be paused when idle). Re-create by re-opening the PR or pushing to the branch. |
| Data | `with_data:false`; before UAT: 0 products, 0 connect consumers, 0 tokens, 0 customer-like rows |
| Migration ledger | 487 versions, last `20261118210000 gifting_enquiry_receiver_v1`; replayed by the integration |
| Deployed source | `gifting-enquiries` v1, `verify_jwt:false`; deployed `index.ts` and `_shared/giftingEnquiryReceiver.ts` match this PR's files |
| Authentication | `verify_jwt=false` is safe only because the bearer token is verified inside `gifting_enquiry_receive_v1` (profile `gifting_enquiries_v1` + scope `enquiries:gifting:write`); see section 3 |
| Grants | RLS on; `anon`/`authenticated` have no table privilege; `service_role` only; receiver `SECURITY DEFINER` with fixed `search_path`; executable by `service_role` only; 0 RLS policies (deny by default), 0 triggers |
| Advisors | only the intentional INFO `rls_enabled_no_policy`; the SECURITY DEFINER WARN/ERROR findings are pre-existing Core objects |

## 2. Credentials

Governed contract (`connect_admin_register_consumer_v1` → `connect_admin_bind_profile_v1` → `connect_admin_issue_token_v1`), consumer
`gifting-uat-synthetic-pr557` (`b2c_website`, environment `preview`), tokens generated **inside the database** and never returned:
valid (2 h expiry, write scope), expired, wrong scope (`catalogue:read`), revoked. After the run the valid and wrong-scope
tokens were revoked (`live_tokens = 0`) and the consumer set to `suspended`. One synthetic enquiry row remains as evidence.
A real Gifting preview token is **not** provisioned: it must be issued by a service-role operator and stored directly in the
Gifting Vercel *Preview* environment (`GIFTING_ENQUIRIES_ENDPOINT`, `GIFTING_ENQUIRIES_TOKEN`); owner: Mission Control / Core.

## 3. Results

### 3a. Hosted preview branch, database level (18/18 pass)
One `execute_sql` call (script in section 5a). Hosted HTTP could **not** be exercised: the agent session's network policy blocks the
Supabase functions host and `*.vercel.app`, so database tests alone do **not** establish hosted HTTP acceptance.

| Step | Result |
|---|---|
| A first delivery | accepted, not a replay; exactly one row |
| B identical replay | same `enquiryId`, `replayed:true`; still one row |
| C conflicting replay | `GIFTING_ENQUIRY_PAYLOAD_CONFLICT`; stored message unchanged |
| D replay after the rejected conflict | succeeds, same `enquiryId` |
| E malformed / unknown / expired / wrong-scope / revoked credential | `CONNECT_TOKEN_INVALID` / `CONNECT_AUTHORIZATION_DENIED` ×3 / `CONNECT_SCOPE_DENIED`; 0 rows written |
| F `newsletter` and `rewards` | `GIFTING_ENQUIRY_INVALID`; 0 rows |
| G valid token after revocation | `CONNECT_AUTHORIZATION_DENIED` |

### 3b. Real HTTP + real website sender, local TLS (21/21 pass; not the hosted branch)
Core's actual `handleGiftingEnquiryRequest` served over TLS on localhost, backed by PostgreSQL 16 with the actual CONNECT-2 and
receiver migrations (`verify_jwt` is irrelevant locally; token validation is the same RPC), called by the website's actual
`sendGiftingEnquiry` from Gifting PR #37 (head `d8a7453`). Scripts in 5b.

| Scenario | Result |
|---|---|
| first delivery | sender records `synced`; 1 row |
| identical replay | HTTP 200, same `enquiryId`, `replayed:true`; sender accepts the receipt; 1 row |
| conflicting replay | HTTP 409, sender reports failure, stored enquiry unchanged |
| 25 concurrent deliveries of one lead | 25/25 `synced`, exactly 1 row (`receipt_count` 25) |
| failed retry (receiver unreachable) | sender reports failure; stored row intact; an already-`synced` record is never resent |
| `newsletter` / `rewards` | sender skips without calling; direct POST → 422; 0 rows |
| missing / invalid / expired / wrong-scope credential | 401 / 401 / 401 / 403; 0 rows written |
| bad idempotency key | 400 |

Website-side protection of a recorded success against a later failed retry (the `markSync` update predicate) is covered by
the #37 unit tests and its Website-staging rollback-only transaction, not re-proven here.

## 4. Remaining before Gifting Preview acceptance
Operator-issued real preview token → Gifting Vercel Preview env; hosted HTTP run from an environment with egress to the preview
function URL; Central staff queue and read grant; retention policy. The preview branch is temporary: for durable acceptance a named
persistent staging target is still a Mission Control decision (Core #495).

## 5. Reproduce

### 5a. Hosted/Branch SQL UAT
Run the scenario in `supabase/tests/gifting_enquiry_receiver_v1.test.sql` (pgTAP, rolled back) on any branch, or the equivalent
`DO` block that registers a consumer, binds `gifting_enquiries_v1`, issues the four token variants inside the block, exercises
A–G, records rows in a temp table and revokes every live token before returning only pass/fail rows. Never `RETURN` a token.

### 5b. Local HTTP + sender harness
Prerequisites: PostgreSQL 16, Deno 2, Bun, OpenSSL. Apply `20260927220000_connect2_consumer_channel_authority.sql` then
`20261119020000_gifting_enquiry_receiver_v1.sql` followed by
`20261119020050_gifting_enquiry_receiver_validation.sql`,
`20261119020051_gifting_enquiry_receiver_hash_timezone.sql` and
`20261119020052_gifting_enquiry_replay_recovery.sql` to a scratch database (roles `anon`,`authenticated`,`service_role`; `pgcrypto` in
schema `extensions`). Create a self-signed cert for `localhost`/`127.0.0.1`, provision tokens with the admin functions into a
local env file (`TOK_OK`, `TOK_EXPIRED`, `TOK_SCOPE`), start `server.ts`, then run `run.ts` with `NODE_EXTRA_CA_CERTS=cert.pem` and
no proxy. `run.ts` imports `sendGiftingEnquiry` and `types.ts` copied from Gifting PR #37.

`server.ts`
```ts
import pg from "npm:pg@8.13.1";
import { handleGiftingEnquiryRequest, type ReceiveFn } from "<repo>/supabase/functions/_shared/giftingEnquiryReceiver.ts";
const pool = new pg.Pool({ host: "127.0.0.1", port: 5544, user: "postgres", database: "core_e2e", max: 40 });
const receive: ReceiveFn = async (token, lead, payload) => {
  try {
    const r = await pool.query("select public.gifting_enquiry_receive_v1($1,$2::uuid,$3::jsonb) as r", [token, lead, JSON.stringify(payload)]);
    return { data: r.rows[0].r, error: null };
  } catch (e) { console.error("db-adapter-error:", (e as Error).message.slice(0, 120)); return { data: null, error: { message: (e as Error).message, code: (e as { code?: string }).code } }; }
};
Deno.serve({ port: 8443, hostname: "127.0.0.1", cert: Deno.readTextFileSync("cert.pem"), key: Deno.readTextFileSync("key.pem"), onListen: () => console.log("listening") },
  (req) => handleGiftingEnquiryRequest(req, receive));
```

`run.ts`
```ts
import { sendGiftingEnquiry } from "./src/lib/gifting-enquiry-handoff.server";
import { execSync } from "node:child_process";
import { readFileSync } from "node:fs";
import { randomUUID } from "node:crypto";

const env = Object.fromEntries(readFileSync("tokens.env", "utf8").trim().split("\n").map((l) => l.split(/=(.*)/s).slice(0, 2)));
const ENDPOINT = "https://127.0.0.1:8443/";
const psql = (q: string) => execSync(`/usr/lib/postgresql/16/bin/psql -h /tmp -p 5544 -U postgres -d core_e2e -Atq -c "${q}"`).toString().trim();
const rows = (id: string) => Number(psql(`select count(*) from gifting_enquiries where source_lead_id='${id}'`));
const results: Array<[string, boolean, string]> = [];
const check = (name: string, ok: boolean, detail = "") => { results.push([name, ok, detail]); console.log(`${ok ? "PASS" : "FAIL"}  ${name}  ${detail}`); };

const record = (over: Record<string, unknown> = {}) => ({
  id: randomUUID(), kind: "corporate", key: "k", email: "synthetic@example.invalid", phone: "+919999900000",
  name: "Synthetic Buyer", company: "Example Co", message: "synthetic e2e", attribution: { utm_source: "e2e" },
  consent: { marketing: false, timestamp: null }, source: "e2e-synthetic", submissionCount: 1,
  createdAt: new Date().toISOString(), updatedAt: new Date().toISOString(), syncState: "pending_sync", ...over,
}) as never;
const raw = async (token: string | null, lead: string, body: unknown, extra: Record<string, string> = {}) => {
  const h: Record<string, string> = { "content-type": "application/json", "idempotency-key": lead, ...extra };
  if (token) h.authorization = `Bearer ${token}`;
  const r = await fetch(ENDPOINT, { method: "POST", headers: h, body: JSON.stringify(body) });
  return { status: r.status, json: await r.json().catch(() => null) as Record<string, unknown> | null };
};
const bodyOf = (r: { id: string; kind: string; email?: string; phone?: string; name?: string; company?: string; message?: string; source: string; consent: unknown; attribution: unknown }) =>
  ({ kind: r.kind, email: r.email ?? null, phone: r.phone ?? null, name: r.name ?? null, company: r.company ?? null, message: r.message ?? null, source: r.source, consent: r.consent, attribution: r.attribution });

// 1. first delivery through the real website sender
const a = record() as ReturnType<typeof record> & { id: string };
const o1 = await sendGiftingEnquiry(a, { endpoint: ENDPOINT, token: env.TOK_OK });
check("1 first delivery: website sender records synced", o1.status === "synced", JSON.stringify(o1));
check("1 exactly one enquiry persisted", rows(a.id) === 1, `rows=${rows(a.id)}`);
// 2. identical replay: same enquiry id (raw HTTP shows the receipt the sender validates)
const r1 = await raw(env.TOK_OK, a.id, bodyOf(a as never));
const r2 = await raw(env.TOK_OK, a.id, bodyOf(a as never));
check("2 identical replay returns 200 + same enquiryId", r2.status === 200 && r1.json?.enquiryId === r2.json?.enquiryId && r2.json?.replayed === true, `${r1.status}/${r2.status} id=${String(r2.json?.enquiryId).slice(0, 8)}`);
const o2 = await sendGiftingEnquiry({ ...(a as object), syncState: "pending_sync" } as never, { endpoint: ENDPOINT, token: env.TOK_OK });
check("2 website sender accepts the replay receipt", o2.status === "synced", JSON.stringify(o2));
check("2 still one row", rows(a.id) === 1);
// 3. conflicting replay
const msgBefore = psql(`select message from gifting_enquiries where source_lead_id='${a.id}'`);
const c = await raw(env.TOK_OK, a.id, { ...bodyOf(a as never), message: "CHANGED" });
const oc = await sendGiftingEnquiry({ ...(a as object), message: "CHANGED" } as never, { endpoint: ENDPOINT, token: env.TOK_OK });
check("3 conflicting replay: HTTP 409, sender reports failure", c.status === 409 && oc.status === "failed", `http=${c.status} sender=${oc.status}`);
check("3 stored enquiry not overwritten", psql(`select message from gifting_enquiries where source_lead_id='${a.id}'`) === msgBefore);
// 4. concurrency: 25 simultaneous deliveries of one lead through the real sender
const b = record({ message: "concurrent" }) as { id: string };
const outs = await Promise.all(Array.from({ length: 25 }, () => sendGiftingEnquiry(b as never, { endpoint: ENDPOINT, token: env.TOK_OK })));
check("4 concurrent deliveries: all synced", outs.every((o) => o.status === "synced"), outs.map((o) => o.status).filter((s) => s !== "synced").join(",") || "25/25");
check("4 concurrent deliveries: exactly one row", rows(b.id) === 1, `rows=${rows(b.id)} receipts=${psql(`select receipt_count from gifting_enquiries where source_lead_id='${b.id}'`)}`);
// 5. failed retry cannot overwrite recorded success (receiver side + sender skip of synced records)
const down = await sendGiftingEnquiry(a, { endpoint: "https://127.0.0.1:9/", token: env.TOK_OK });
check("5 failed retry (receiver unreachable) reports failure but row intact", down.status === "failed" && rows(a.id) === 1 && psql(`select message from gifting_enquiries where source_lead_id='${a.id}'`) === msgBefore, JSON.stringify(down));
const skipped = await sendGiftingEnquiry({ ...(a as object), syncState: "synced" } as never, { endpoint: ENDPOINT, token: env.TOK_OK });
check("5 already-synced record is never resent", skipped.status === "skipped");
// 6. marketing-only submissions never enter the queue
const nl = record({ kind: "newsletter" }) as { id: string };
const rw = record({ kind: "rewards" }) as { id: string };
const sNl = await sendGiftingEnquiry(nl as never, { endpoint: ENDPOINT, token: env.TOK_OK });
const sRw = await sendGiftingEnquiry(rw as never, { endpoint: ENDPOINT, token: env.TOK_OK });
const hNl = await raw(env.TOK_OK, nl.id, bodyOf(nl as never));
const hRw = await raw(env.TOK_OK, rw.id, bodyOf(rw as never));
check("6 sender skips newsletter/rewards without calling the receiver", sNl.status === "skipped" && sRw.status === "skipped");
check("6 receiver rejects them with 422 even if posted directly", hNl.status === 422 && hRw.status === 422, `${hNl.status}/${hRw.status}`);
check("6 no marketing-only row exists", rows(nl.id) === 0 && rows(rw.id) === 0);
// 7. credentials over real HTTP: missing/invalid/expired/wrong-scope never write
const d = record() as { id: string };
const bd = bodyOf(d as never);
const cases: Array<[string, string | null, number]> = [["missing", null, 401], ["invalid", "x".repeat(48), 401], ["expired", env.TOK_EXPIRED, 401], ["wrong-scope", env.TOK_SCOPE, 403]];
for (const [name, tok, want] of cases) { const r = await raw(tok, d.id, bd); check(`7 ${name} credential -> HTTP ${want}`, r.status === want, `got ${r.status}`); }
check("7 no row written by any rejected credential", rows(d.id) === 0);
const bad = await raw(env.TOK_OK, d.id, bd, { "idempotency-key": "not-a-uuid" });
check("7 bad idempotency key -> 400", bad.status === 400);
const total = psql(`select count(*) from gifting_enquiries`);
check("8 queue contains only the 2 expected synthetic enquiries", total === "2", `total=${total}`);
const failed = results.filter(([, ok]) => !ok).length;
console.log(`\n${results.length - failed}/${results.length} checks passed`);
process.exit(failed ? 1 : 0);
```
