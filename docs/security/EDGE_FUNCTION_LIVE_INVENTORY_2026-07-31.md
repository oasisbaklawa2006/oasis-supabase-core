# Live Edge Function Inventory — 2026-07-31

Supabase project: `tcxvcatsqqertcnycuop`

The Supabase management inventory reports **26 ACTIVE functions**: 5 with platform JWT verification enabled and 21 with it disabled. `verify_jwt=false` is not automatically a vulnerability, but every such function must prove an appropriate custom authentication boundary or be quarantined.

## Platform JWT enabled

| Function | Version | Classification |
|---|---:|---|
| `send-whatsapp` | 108 | Authenticated outbound operation; source/role contract still requires canonical capture |
| `send-whatsapp-automation` | 25 | Authenticated automation operation; service caller contract requires verification |
| `whatsapp-operator-reply` | 25 | Authenticated operator operation |
| `catalogue-ai-copy` | 4 | Approved preview function; staff authorization and human review required |
| `submit-central-scan` | 4 | Authenticated scan submission; ownership and role contract require verification |

## Platform JWT disabled

| Function | Version | Required disposition |
|---|---:|---|
| `send-email` | 109 | Inspect custom auth and caller; quarantine if unauthenticated |
| `generate-product-attributes` | 96 | **QUARANTINED** — unsafe compliance-generation behaviour and live/repo drift |
| `whatsapp-webhook` | 121 | Public provider callback; dedicated deployment only; verify Meta signature/token and replay controls |
| `public-order-tracking` | 78 | Public by design only if opaque token, enumeration resistance and rate limiting are proven |
| `whatsapp-otp` | 80 | Public OTP endpoint; rate limit, expiry, replay and abuse controls required |
| `admin-create-draft` | 77 | Function body validates JWT and ADMIN/SUPER_ADMIN, but platform JWT should be enabled after caller compatibility test |
| `notify-event` | 63 | Inspect custom/service authentication; no public mutation allowed |
| `banyan-central-parser` | 59 | Inspect caller and data-write authority; likely internal-only |
| `generate-rescue-ledger` | 58 | Financial/reporting operation; must be authenticated and role-gated |
| `generate-bi-monthly-ledger` | 57 | Financial/reporting operation; must be authenticated and role-gated |
| `oasis-ai-chat` | 55 | Inspect user auth, origin, prompt injection, cost and data-exfiltration controls |
| `msg91-otp` | 50 | Public OTP endpoint; rate limit, expiry, replay and provider controls required |
| `validate-user` | 46 | Public only if it reveals no account-enumeration information and is rate limited |
| `msg91-webhook` | 34 | Public provider callback; signature/secret and replay controls required |
| `whatsapp-message-stitcher` | 27 | Internal processor; service authentication and idempotency required |
| `whatsapp-identify-sender` | 24 | Internal processor; service authentication and least-privilege writes required |
| `whatsapp-classify-intent` | 21 | Internal processor; service authentication and bounded AI/rule behaviour required |
| `whatsapp-route-packet` | 21 | Internal processor; service authentication, idempotency and authority routing required |
| `barcode-scan-ingest` | 20 | Ingestion endpoint; device/user authentication and replay protection required |
| `whatsapp-studio-inbox-webhook` | 19 | Public/custom-auth Studio ingress; exact caller and purpose must be revalidated |
| `whatsapp-studio-inbox-bridge` | 29 | Approved custom-secret controlled service; keep `BRIDGE_ENABLED=false` by default |

## Immediate conclusions

1. The previous five-function repository view was incomplete; production contains 26 active functions.
2. Twenty-one functions bypass platform JWT verification. Each must be source-reviewed before any deployment or auth-mode change.
3. `admin-create-draft` already performs token and role validation inside the function, but leaving platform verification disabled expands attack surface and should be corrected after an invocation compatibility test.
4. No bulk redeployment or bulk `verify_jwt` change is safe. Provider callbacks and custom-secret cron functions legitimately need different handling from user/admin APIs.
5. The canonical repository does not yet contain reviewed source for every live function. Until source and checksums are captured, production remains the only copy for several functions and this is a governance defect.
