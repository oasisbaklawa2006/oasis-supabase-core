# WhatsApp Webhook Recertification — 2026-07-31

## Scope

Production Edge Function: `whatsapp-webhook`

Production version recorded by the Edge Function registry: `121`.

Repository source: `supabase/functions/whatsapp-webhook/index.ts`.

Owner: legacy ERP / Central backend path.

## Recertification result

**NOT CERTIFIED FOR DEPLOYMENT.**

The current repository implementation must remain protected from deployment until the provider authentication boundary is rebuilt and runtime-tested against the actual production callback provider.

## Confirmed controls

- The function is excluded from `supabase/config.toml` preview deployment.
- Repository governance rejects broad Edge Function deployment commands.
- Provider message ID deduplication is present for replay/idempotency handling after payload acceptance.
- Automatic order writes and owner reassignment are controlled by explicit feature flags.
- Studio inbox fan-out is non-blocking and must not replace the legacy ERP path.

## Blocking findings

1. GET verification accepts and returns a challenge without validating the supplied verification token against a configured secret.
2. Verification-token candidates are written to logs.
3. POST requests are parsed before any provider signature or shared-secret authentication is established.
4. No `X-Hub-Signature-256` or equivalent provider signature validation is present in the canonical source.
5. The accepted payload formats include Meta-style and alternate-provider shapes, but the production provider contract and corresponding authentication mechanism are not pinned in repository evidence.
6. Wildcard CORS is present even though this endpoint is a server-to-server provider callback.
7. The function performs service-role database writes and downstream calls, so unauthenticated payload acceptance has a high blast radius.

## Required certification gates

The function may only be certified after all of the following are complete:

- Confirm the active production callback provider and exact authentication contract.
- Capture the deployed version 121 source or prove byte-for-byte equivalence with repository source.
- Replace handshake behavior with constant-time verification-token validation and remove secret/token logging.
- Verify POST payload authenticity before JSON parsing or side effects.
- Add bounded body size, timestamp/replay controls and provider-message idempotency tests.
- Replace wildcard CORS with no browser CORS policy unless a documented browser caller exists.
- Exercise provider handshake, valid signed payload, invalid signature, replay and malformed-payload tests in a non-production environment.
- Use a dedicated approval-gated deployment followed by runtime evidence and rollback verification.

## Disposition

Procedure 4 recertification review is complete with a **failed certification outcome**. The correct security disposition is continued quarantine from repository-driven deployment, not an unsafe declaration of readiness.

No production deployment, callback change, secret change or authentication-mode change is authorized by this record.
