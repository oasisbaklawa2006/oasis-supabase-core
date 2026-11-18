# Gifting enquiry receiver contract (GFT-100 / Central #677)

Status: **candidate, not deployed.** No consumer is registered, no token is issued and no
Edge Function is deployed by the change that introduces this document.

Parties: Gifting website (`oasisbaklawa2006/oasis-baklawa-gifting`, PR #37 sender) → Core
(persistence, this repository) → Central (staff Gifting Enquiries queue, separate work item).

## Flow

1. The website saves the enquiry in Website Supabase and obtains a row UUID (`source lead id`).
2. A server-side call forwards it to the receiver with that UUID as `Idempotency-Key`.
3. Core stores exactly one row per `(consumer, source lead id)` and returns a stable `enquiryId`.
4. The website records `synced` only after a receipt that matches the contract below.

Marketing-only records (newsletter, rewards) are **not** accepted; they stay on the existing
Klaviyo consent path.

## HTTP contract (`supabase/functions/gifting-enquiries`)

`POST /functions/v1/gifting-enquiries`

| Header | Requirement |
|---|---|
| `Authorization` | `Bearer <Connect token>` (scope `enquiries:gifting:write`, consumer bound to profile `gifting_enquiries_v1`) |
| `Idempotency-Key` | the source lead UUID |
| `Content-Type` | `application/json`, body ≤ 16 KiB |

Body: `kind` (`contact` \| `corporate` \| `wedding` \| `partnership`), `email`, `phone`, `name`,
`company`, `message` (nullable strings), `source` (2–80 chars), `consent`
(`{marketing: boolean, timestamp: string \| null}`), `attribution` (string map, ≤ 20 keys).
Unknown fields are rejected. Field limits mirror the website's own lead schema.

| Outcome | Status | Body |
|---|---|---|
| First delivery | 201 | `{status:"accepted", queue:"gifting_enquiries", sourceLeadId, enquiryId, replayed:false}` |
| Exact replay (same payload) | 200 | same `enquiryId`, `replayed:true` |
| Different payload for the same source lead | 409 | `{error:"payload_conflict"}`; stored row unchanged |
| Missing/invalid/unknown/expired/revoked token, wrong profile | 401 | `{error:"unauthorized"}` |
| Token lacks the write scope | 403 | `{error:"forbidden"}` |
| Invalid payload | 422 | `{error:"invalid_payload"}` |
| Missing/invalid idempotency key, bad JSON | 400 | |
| Wrong method / media type / oversize | 405 / 415 / 413 | |
| Infrastructure fault or unverifiable receipt | 503 + `Retry-After` | sender retries with the same key |

Error bodies never echo database detail, the token or personal data.

## Database contract (`20261118210000_gifting_enquiry_receiver_v1.sql`)

- `public.gifting_enquiries`: RLS on, no `anon`/`authenticated` access, `service_role` only.
  Unique `(consumer_id, source_lead_id)`; `payload_hash` (SHA-256 of the normalised, key-order
  independent payload) decides replay vs conflict; `receipt_count` counts deliveries.
- `public.gifting_enquiry_receive_v1(text, uuid, jsonb)`: `SECURITY DEFINER`, fixed `search_path`,
  executable by `service_role` only. Uses the CONNECT-2 token store (hashed tokens, revocation,
  expiry, consumer status, environment binding) but its **own** resource and scope, so the existing
  catalogue read path and its allowlists are unchanged and an enquiry token cannot read the catalogue.
- Profile `gifting_enquiries_v1` (write-only, exposes no resource or field for reading).

Evidence in this change: 44 SQL contract assertions (replay, conflict, tenant isolation, every
authentication failure, validation, no-write-on-reject), each mutation-checked; 30 concurrent
identical deliveries produced one row and one `enquiryId`; 20 concurrent deliveries with two
different payloads produced one row, 10 accepted and 10 conflicts; 11 Deno tests for the HTTP
boundary, including the website's own receipt checks.

## Provisioning (governed, staging only; no secret in chat or in source)

1. Mission Control records the Core/Central owners and names one **isolated** staging target with
   verified migration replay (Core #495: do not reuse Buyer, WA-100 or Genie branches; Core `main`
   currently reports `MIGRATIONS_FAILED`).
2. Apply this migration to that target through the governed release lane.
3. As `service_role`: `connect_admin_register_consumer_v1('gifting-website-enquiries-staging',
   'b2c_website', 'staging', …)`, `connect_admin_bind_profile_v1(…, <gifting_enquiries_v1>, 'staging')`,
   `connect_admin_issue_token_v1(…, ARRAY['enquiries:gifting:write'], 'staging', <expiry>)`.
4. Deploy `gifting-enquiries` through a governed release step to that target only.
5. Store the endpoint URL and the token **directly** in the Gifting Vercel *Preview* environment
   (`GIFTING_ENQUIRIES_ENDPOINT`, `GIFTING_ENQUIRIES_TOKEN`); verify the deployment commit.
6. Acceptance (Central #677): submit one synthetic enquiry with marketing consent off, deliver the
   same source UUID twice; expect one `gifting_enquiries` row, the same `enquiryId` in both
   receipts, a synced website row and zero marketing events.

## Not included / open decisions

- Central staff queue and staff read access (separate Central work item; the table is
  `service_role` only until that grant is reviewed).
- Retention period and deletion process for enquiry personal data (business/legal decision).
- Per-token rate limiting (`connect_tokens.rate_limit_per_minute` is stored but not enforced by
  CONNECT-2 either); abuse protection at the gateway.
- Production consumer, token and deployment: not authorised by this change.
