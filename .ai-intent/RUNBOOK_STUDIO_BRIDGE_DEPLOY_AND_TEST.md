# Runbook — Studio Bridge Deploy and Test

## Function

```txt
whatsapp-studio-inbox-bridge
```

## Project

```txt
tcxvcatsqqertcnycuop
```

## Deploy

```bash
cd ~/oasis-ai-studio
npx supabase functions deploy whatsapp-studio-inbox-bridge --project-ref tcxvcatsqqertcnycuop --no-verify-jwt
```

## Dry-Run

```bash
cd ~/oasis-ai-studio
BRIDGE_SECRET="$(cat ~/.oasis_bridge_cron_secret.txt)"

curl -X POST "https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/whatsapp-studio-inbox-bridge" \
-H "Authorization: Bearer $BRIDGE_SECRET" \
-H "Content-Type: application/json" \
-d '{"dry_run":true,"limit":5}'
```

## Live Controlled Test

Enable:

```bash
npx supabase secrets set BRIDGE_ENABLED=true --project-ref tcxvcatsqqertcnycuop
```

Ingest:

```bash
curl -X POST "https://tcxvcatsqqertcnycuop.supabase.co/functions/v1/whatsapp-studio-inbox-bridge" \
-H "Authorization: Bearer $BRIDGE_SECRET" \
-H "Content-Type: application/json" \
-d '{"dry_run":false,"limit":5}'
```

Disable:

```bash
npx supabase secrets set BRIDGE_ENABLED=false --project-ref tcxvcatsqqertcnycuop
```

## Expected Success

```txt
ok: true
rows_failed: 0
rows_ingested >= 1 for live test
```

## Troubleshooting

| Error | Meaning | Fix |
|---|---|---|
| unauthorized | Local secret does not match Supabase `BRIDGE_CRON_SECRET` | Reapply secret from local file |
| bridge disabled | `BRIDGE_ENABLED=false` and dry_run is false | Enable only for controlled test |
| rows_read 0 | No ERP rows after cursor | Check webhook / cursor |
| resolver_status failed | Resolver runtime issue | Inspect edge logs and catalog loader |

## Do Not

- Do not deploy `whatsapp-webhook`.
- Do not enable cron during debugging.
- Do not paste secret values into terminal screenshots or chat.
