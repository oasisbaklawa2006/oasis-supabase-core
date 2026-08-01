# WhatsApp Webhook Runtime Evidence — 2026-07-31

Project: `tcxvcatsqqertcnycuop`
Function: `whatsapp-webhook`
Observed production version: `121`
Observed deployment hash: `e242369366401ace5096857fd4c7bad22b921f25c3608087853c6d8716971aeb`
Observed platform JWT mode: `false`

## Source identity

Production source was retrieved directly from Supabase and compared with the canonical repository path `supabase/functions/whatsapp-webhook/index.ts`. The inspected source contains the same insecure webhook boundary previously recorded by Procedure 4.

## Confirmed runtime findings

1. GET verification returns a challenge whenever a supported challenge parameter is present.
2. The supplied verification token is not compared with a configured expected token.
3. Verification-token candidates are written to logs.
4. POST requests are parsed without validating `X-Hub-Signature-256` or an equivalent provider secret.
5. Wildcard CORS is enabled on a service-to-service callback.
6. The function has service-role database access and performs high-impact writes and downstream calls.
7. Message-ID duplicate handling exists after request acceptance, but it is not a substitute for provider authentication.
8. Risky automatic order writes and owner reassignment are guarded by disabled-by-default environment flags.

## Certification decision

Production certification remains **WITHHELD**. Version 121 must not be redeployed as a certified implementation.

## Mandatory hardening contract

A replacement version must:

- compare `hub.verify_token` against `WHATSAPP_WEBHOOK_VERIFY_TOKEN` without logging either value;
- validate `X-Hub-Signature-256` with HMAC-SHA256 over the exact raw request body using `WHATSAPP_META_APP_SECRET`;
- reject missing, malformed and invalid signatures before JSON parsing, database access, downstream calls, or payload logging;
- return no wildcard browser CORS headers;
- retain duplicate-message protection and disabled-by-default risky mutation flags;
- provide structured security-result codes without payload, token, signature or secret logging;
- preserve a rollback reference to production version 121;
- undergo invalid-token, missing-signature, invalid-signature, valid-signature and duplicate-delivery runtime tests before callback cutover.

## Runtime evidence still required

- Redacted proof that both required secrets exist in the production project.
- Successful GET challenge using the configured token.
- Rejected GET challenge using an incorrect token.
- Unsigned POST rejected before JSON parsing, database access, downstream calls, or payload logging.
- Incorrectly signed POST rejected before JSON parsing, database access, downstream calls, or payload logging.
- Accepted correctly signed non-mutating fixture.
- Duplicate fixture accepted once and discarded on replay.
- Log review proving no payload, token, signature or secret value is emitted.
- Credential-path review proving no payload content is logged before authentication.
- Rollback rehearsal and exact prior version reference.

## Current disposition

- Current production callback: active, operational, quarantined.
- Repository security primitive: prepared in `supabase/functions/_shared/whatsappWebhookSecurity.ts`.
- Production deployment of hardening: blocked until the secret-sync workflow is validated, the required secrets are confirmed, provider authentication compatibility is confirmed, and the handler is integrated and tested with the required authentication and replay fixtures.
