# WhatsApp Studio Inbox Bridge Certification

Date: 2026-07-31
Function: `whatsapp-studio-inbox-bridge`
Production version reviewed: 29
Repository source: `supabase/functions/whatsapp-studio-inbox-bridge/index.ts`

## Certification outcome

**CERTIFIED FOR CONTROLLED, MANUAL EXECUTION ONLY.**

This is a repository-level certification of the function boundary and fail-closed controls. It is not a production runtime certification and does not authorize unattended scheduling or broad deployment.

## Confirmed controls

- Requests are limited to POST, with OPTIONS handled separately.
- A non-empty `BRIDGE_CRON_SECRET` is mandatory.
- Authorization requires an exact bearer-secret match.
- Non-dry-run processing remains disabled unless `BRIDGE_ENABLED=true`.
- Batch size is bounded to 1–500 rows.
- The source table defaults to `whatsapp_messages` and is configurable only through an environment variable.
- Only inbound rows after the persisted cursor are read.
- Processing uses deterministic ordering by timestamp and row ID.
- Duplicate detection is performed before RPC ingestion.
- Cursor and run statistics are persisted after processing.
- Per-row failures are recorded and do not silently advance failed rows.
- The bridge is isolated from the production Meta callback and does not own provider callback handling.

## Residual risks and operating restrictions

1. The function uses the Supabase service-role key and therefore has a high-privilege database boundary.
2. Bearer-secret comparison is exact but not constant-time; exposure remains acceptable only for controlled server-to-server use over TLS.
3. `cursor_override`, `backfill`, and configurable source-table behavior are privileged operator controls and must not be exposed to end users.
4. Dry-run mode still performs privileged database reads.
5. Runtime evidence is still required before recurring scheduling is enabled.

## Mandatory deployment and execution rules

- Deploy only by explicit function name.
- Keep `BRIDGE_ENABLED=false` by default.
- Do not expose the endpoint through browser UI or public clients.
- Store `BRIDGE_CRON_SECRET` only in approved secret storage.
- Rotate the secret if disclosure is suspected.
- First production execution must be `dry_run=true` with a small bounded limit.
- Validate row counts, duplicate handling, cursor behavior, and destination records before enabling a controlled ingestion window.
- Recurring scheduling remains prohibited until Procedure 8 runtime certification.

## Procedure closure

Procedure 5 is complete at repository-certification level. The function is approved only for controlled manual testing under the restrictions above. Runtime activation and recurring scheduling remain pending Procedure 8.
