# Secrets Inventory Template

## Purpose

List secret names, owners, storage locations, and rotation policy. Do not store secret values in this file.

## Rules

- No secret values in Git.
- No secret values in chat.
- No secret values in screenshots.
- No secret values in PR descriptions.
- No secret values in issue comments.
- Store local development bridge secret only at protected local path.

## Known Secret Names

| Secret Name | Owner | Where Used | Value Location | Rotation Policy |
|---|---|---|---|---|
| `BRIDGE_CRON_SECRET` | AI Studio | `whatsapp-studio-inbox-bridge` Authorization header | Local dev: `~/.oasis_bridge_cron_secret.txt`; Supabase secret store | Rotate at final go-live and whenever exposed |
| `BRIDGE_ENABLED` | AI Studio | Bridge safety gate | Supabase secret store | Keep false during development unless controlled test |
| `SUPABASE_ACCESS_TOKEN` | Developer machine | Supabase CLI login alternative | Local env only | Rotate if exposed |
| `VITE_SUPABASE_URL` | Frontend | Supabase project URL | `.env` / Vercel | Public-ish but still manage carefully |
| `VITE_SUPABASE_ANON_KEY` | Frontend | Supabase anon access | `.env` / Vercel | Public client key; RLS must protect data |
| `SUPABASE_SERVICE_ROLE_KEY` | Server only | privileged DB calls | Server env only | Never expose to frontend |
| `MSG91_*` | Auth/OTP | OTP delivery | server env/provider dashboard | Rotate at go-live |
| `META_WHATSAPP_VERIFY_TOKEN` | Legacy webhook | Meta webhook verification | server env/provider dashboard | Rotate if exposed |
| `META_WHATSAPP_ACCESS_TOKEN` | Legacy webhook/provider | WhatsApp API | server env/provider dashboard | Rotate if exposed |

## Current Development Policy

```txt
BRIDGE_ENABLED=false
```

Bridge tests should use:

```bash
BRIDGE_SECRET="$(cat ~/.oasis_bridge_cron_secret.txt)"
```

Never manually paste the secret into curl commands.

## Final Go-Live Policy

Before scheduled polling or production handover:

1. Rotate `BRIDGE_CRON_SECRET`.
2. Confirm old exposed secret is unauthorized.
3. Confirm new secret works with dry-run.
4. Keep secret values outside documentation.
5. Record only rotation date/status, never value.
