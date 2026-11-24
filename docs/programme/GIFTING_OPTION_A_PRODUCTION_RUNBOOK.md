# Gifting Option A — Core Production runbook

Status: owner-authorised for merge in this PR. **Nothing in this document is executed by the PR itself.** Each step runs only after its explicit owner approval.

## Invariants

- **Single backend.** Core Production `tcxvcatsqqertcnycuop` is the only authoritative backend for Gifting leads, enquiries and the catalogue. There is no separate Gifting production Supabase project.
- **Production Connect environment only.** Every consumer, binding and token Gifting uses in Option A has `CONNECT_ENV = 'production'`. The `staging` steps in `GIFTING_ENQUIRY_RECEIVER_CONTRACT.md` are **never** run against `tcxvcatsqqertcnycuop`.
- **Consumer:** `oasis_gifting_website_prod`, type `b2c_website`.
- **Profiles and scopes:** `website_retail_v1` with scope `catalogue.products`; `gifting_enquiries_v1` with scope `enquiries:gifting:write`.
- **Fail-closed payments.** `PAYMENT_PROVIDER`, `RAZORPAY_*`, `STRIPE_*` and Shiprocket configuration stay unset, so checkout returns 503.

## Step 1 — Apply `website_leads` (Production Migration Release)

1. Merge this PR. The merge runs only the read-only preflight (`auto-production-migration-dispatch`). It does not write to Production.
2. In GitHub Actions, run **Production Migration Release** with `deploy = true` and `release_sha` = the merge commit SHA on `main`.
3. Approve the `supabase-production` environment.
4. Verify (read-only):

```sql
select to_regclass('public.website_leads') as website_leads_table;
```

Expected: `website_leads`. Migration `20261124000000_website_leads_core_authority_v1` is then recorded as applied.

## Step 2 — Deploy `gifting-enquiries` (first deploy)

1. In GitHub Actions, run **Gifting Enquiries Production First Deploy** with `deploy = true` and `release_sha` = the same merge SHA.
2. Approve the `supabase-production` environment.
3. Expected: evidence artifact `gifting-enquiries-first-deploy-<sha>-<attempt>` with status `VERIFIED`. The unauthenticated and invalid-JWT POSTs both return `401`.

**If `main` advanced after Step 1:** the workflow rejects any `release_sha` that is not the current `main` head. Re-check Step 1 against the current `main` (`website_leads` must still exist), then dispatch Step 2 with the current `main` SHA as `release_sha`. Never reuse the old SHA.

## Step 3 — Register consumer, bind profiles, issue tokens

Run in the Supabase SQL editor for project `tcxvcatsqqertcnycuop` only, as `service_role`, and only after Step 2 is `VERIFIED`.

```sql
-- CONNECT_ENV = 'production'
select public.connect_admin_register_consumer_v1(
  'oasis_gifting_website_prod', 'b2c_website', 'production', 'Oasis Gifting website (production)'
);
```

Copy `consumer_id` from the result, then look up both profile ids:

```sql
-- CONNECT_ENV = 'production'
select id from public.connect_profiles where profile_key = 'website_retail_v1';
select id from public.connect_profiles where profile_key = 'gifting_enquiries_v1';
```

Bind both profiles and issue one token per profile. Replace the placeholders with the copied values.

```sql
-- CONNECT_ENV = 'production'
select public.connect_admin_bind_profile_v1('<CONSUMER_ID>'::uuid, '<RETAIL_PROFILE_ID>'::uuid, 'production');
select public.connect_admin_bind_profile_v1('<CONSUMER_ID>'::uuid, '<ENQUIRIES_PROFILE_ID>'::uuid, 'production');

select public.connect_admin_issue_token_v1(
  '<CONSUMER_ID>'::uuid, array['catalogue.products']::text[], 'production', '<EXPIRES_AT>'::timestamptz, 120
);
select public.connect_admin_issue_token_v1(
  '<CONSUMER_ID>'::uuid, array['enquiries:gifting:write']::text[], 'production', '<EXPIRES_AT>'::timestamptz, 120
);
```

Each token result is returned once. Copy its token field straight into the Vercel secret in Step 4. Never paste a token into chat, a ticket, a log or a document.

## Step 4 — Vercel Production environment (project `oasis-baklawa-gifting`, environment Production)

| Variable | Value | Secret |
|---|---|---|
| `OASIS_CORE_SUPABASE_URL` | `https://tcxvcatsqqertcnycuop.supabase.co` | No |
| `OASIS_CORE_PUBLISHABLE_KEY` | Core project publishable key (dashboard) | No |
| `OASIS_CORE_CONNECT_TOKEN` | Step 3 catalogue token | Yes |
| `OASIS_CORE_CONNECT_CONSUMER_KEY` | `oasis_gifting_website_prod` | No |
| `OASIS_CORE_CONNECT_ENV` | `production` | No |
| `GIFTING_ENQUIRIES_ENDPOINT` | `https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/gifting-enquiries` | No |
| `GIFTING_ENQUIRIES_TOKEN` | Step 3 enquiries token | Yes |
| `SUPABASE_URL` | `https://tcxvcatsqqertcnycuop.supabase.co` | No |
| `SUPABASE_SERVICE_ROLE_KEY` | Core service_role key (dashboard) | Yes |

**Left unset for Option A:** `PAYMENT_PROVIDER`, `RAZORPAY_KEY_ID`, `RAZORPAY_KEY_SECRET`, `RAZORPAY_WEBHOOK_SECRET`, `STRIPE_PUBLISHABLE_KEY`, `STRIPE_SECRET_KEY`, `STRIPE_WEBHOOK_SECRET`.

**Optional, deferred:** `SITE_URL`, `APPVERSE_BASE_URL`, `CART_RECOVERY_SECRET`, `CATALOGUE_IMPORT_TOKEN`, `ADMIN_DIAGNOSTICS_TOKEN`.

**Risk, owner decision:** `SUPABASE_SERVICE_ROLE_KEY` on the Gifting Vercel project gives that server full access to Core Production. This is the cost of the single-backend decision. A narrower write path (for example, a single RPC) would remove it, and should be weighed before go-live.

**Redeploy required:** saving these variables does not change existing deployments. Trigger a new Vercel Production deployment after saving them, and wait for it to finish. Step 5 must run against that deployment, not an earlier one.

## Step 5 — Verify end to end

1. Submit one synthetic enquiry through the Gifting site with marketing consent off. Record its submission UUID. This is the `Idempotency-Key` the Gifting server sends, which the receiver stores as `source_lead_id`, and for lead kinds it is the `website_leads.id` of the row it created. Replace `<SOURCE_LEAD_ID>` below with that UUID.
2. Confirm by that ID (read-only):

```sql
-- CONNECT_ENV = 'production'
select id, kind, sync_state, synced_at from public.website_leads where id = '<SOURCE_LEAD_ID>'::uuid;
select count(*) as enquiry_rows from public.gifting_enquiries where source_lead_id = '<SOURCE_LEAD_ID>'::uuid;
```

Expect exactly one `website_leads` row for `<SOURCE_LEAD_ID>` and exactly one `gifting_enquiries` row (`enquiry_rows = 1`). `sync_state = 'synced'` means Core accepted the enquiry. `pending_sync` or `failed` means the handoff did not complete, and go-live must stop until it is investigated.
3. Replay the same submission UUID once. The counts must stay at one, and the same enquiry must be returned.

## Rollback

- **Gifting:** remove `GIFTING_ENQUIRIES_ENDPOINT` and `GIFTING_ENQUIRIES_TOKEN` from Vercel Production and redeploy. Enquiries then return an unavailable state.
- **Revoke a token:** run as `service_role`:

```sql
-- CONNECT_ENV = 'production'
select public.connect_admin_revoke_token_v1('<TOKEN_ID>'::uuid);
```

- **Function removal:** there is no governed removal workflow, and removal needs separate owner approval. Confirm the function is listed for Core Production first, then delete it with the project ref given explicitly, so the CLI's linked project is never used by mistake: `npx supabase@2.117.0 functions delete gifting-enquiries --project-ref tcxvcatsqqertcnycuop`.
- **Lead retention:** `purge_synced_website_leads_v1(<days>)` deletes only synced leads older than `<days>` (minimum 30). It has no scheduler. Run it only with owner approval.
