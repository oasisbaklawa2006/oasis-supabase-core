# Runbook — Secret Rotation

## Purpose

Rotate bridge and development secrets safely without exposing values.

## Bridge Secret Local File

```txt
~/.oasis_bridge_cron_secret.txt
```

## Rotate Bridge Secret

```bash
cd ~/oasis-ai-studio
umask 077
NEW_SECRET=$(openssl rand -hex 32)
printf "%s\n" "$NEW_SECRET" > ~/.oasis_bridge_cron_secret.txt
npx supabase secrets set BRIDGE_CRON_SECRET="$NEW_SECRET" BRIDGE_ENABLED=false --project-ref tcxvcatsqqertcnycuop
```

## Reapply Existing Local Secret

```bash
npx supabase secrets set BRIDGE_CRON_SECRET="$(cat ~/.oasis_bridge_cron_secret.txt)" BRIDGE_ENABLED=false --project-ref tcxvcatsqqertcnycuop
```

## Test

```bash
BRIDGE_SECRET="$(cat ~/.oasis_bridge_cron_secret.txt)"

curl -X POST "https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/whatsapp-studio-inbox-bridge" \
-H "Authorization: Bearer $BRIDGE_SECRET" \
-H "Content-Type: application/json" \
-d '{"dry_run":true,"limit":1}'
```

Expected:

```txt
ok: true
```

## If Supabase CLI Says Access Token Not Provided

Run:

```bash
npx supabase login
```

Then reapply the secret.

## Rules

- Do not paste secrets into chat.
- Do not commit local secret files.
- Do not store actual values in `.ai-intent`.
- Rotate at final go-live.
