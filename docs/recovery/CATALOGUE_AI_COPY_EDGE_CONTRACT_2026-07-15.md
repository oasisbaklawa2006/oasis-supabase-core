# Catalogue AI copy Edge Function contract — 2026-07-15

Status: source-only implementation for review. It has not been deployed and no production secret or database object was changed.

## Purpose

`catalogue-ai-copy` generates eight governed marketing-copy fields from operator-supplied product facts. It is deliberately isolated from the legacy `oasis-ai-chat` and `generate-product-attributes` functions, whose prompts and authentication posture are not suitable for catalogue governance.

## Security and cost controls

- Exact allowed browser origin from `AI_STUDIO_ALLOWED_ORIGIN`; no wildcard CORS.
- Supabase access token is validated with `auth.getUser`, then the existing canonical `is_internal_staff(_user_id uuid)` RPC must return true for that exact user; anonymous and non-staff calls fail closed.
- Uses Supabase's modern injected publishable-key map when available, with a legacy anon-key fallback during project key migration.
- `AI_STUDIO_AI_ENABLED=true` is required, providing an immediate cost-control kill switch.
- `OPENAI_API_KEY` remains server-side. `OPENAI_CATALOGUE_MODEL` is mandatory so model/cost selection is an explicit operations decision.
- One provider request per invocation, 20-second timeout, 1,400 output-token ceiling, no tools or web access, and `Cache-Control: no-store`.
- Strict JSON Schema output and a second local output validator.
- Marketing copy only. Compliance, price, nutrition, allergen, ingredient, tax, certification, health and other unsupported claims are prohibited.
- Every response declares `human_review_required: true`.

## Required deployment configuration (future, separately authorized)

1. Set `OPENAI_API_KEY`, `OPENAI_CATALOGUE_MODEL`, `AI_STUDIO_AI_ENABLED=true`, and the exact production `AI_STUDIO_ALLOWED_ORIGIN` as Edge Function secrets.
2. Deploy with Supabase JWT verification enabled; the implementation also validates the user token itself as defense in depth.
3. Wire the AI Studio gateway to `catalogue-ai-copy` only after a preview deployment passes authenticated positive/negative tests.
4. Do not repoint or overwrite `oasis-ai-chat` or `generate-product-attributes` as part of this change.

## Acceptance tests

- Reject missing/invalid product name, invalid tone, excessive text, and shelf life outside 1–3650 days.
- Reject absent/invalid JWT and unapproved origins.
- Require exactly the eight governed fields; reject extra or empty fields.
- Confirm missing storage/shelf-life facts produce the required operator-confirmation wording.
- Confirm provider failures, invalid JSON, and timeout return safe errors without provider payloads or secrets.

## Repository caveat

The repository's current `supabase/config.toml` still references a non-canonical historical project ID. This change intentionally does not modify that file. No CLI deploy should be run until repository linking is reviewed independently and the target is explicitly confirmed as `tcxvcatsqqertcnycuop`.
