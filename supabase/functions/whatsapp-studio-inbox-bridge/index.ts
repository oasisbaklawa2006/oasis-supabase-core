import { corsHeaders } from "npm:@supabase/supabase-js@2.95.0/cors";
import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { erpTimestampToIso, mapErpWhatsAppMessage } from "../_shared/erpInboxBridge/mapErpWhatsAppMessage.ts";
import { processErpInboundRow } from "../_shared/erpInboxBridge/processErpInboundRow.ts";
import { resolveInboundAtEdge } from "../_shared/resolveInboundAtEdge.ts";
import type { ErpWhatsAppMessageRow } from "../_shared/erpInboxBridge/types.ts";

type BridgeRequest = {
  dry_run?: boolean;
  limit?: number;
  backfill?: boolean;
  cursor_override?: string;
};

type BridgeRunError = {
  erp_row_id: string;
  error: string;
};

function json(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function authorize(req: Request): boolean {
  const secret = Deno.env.get("BRIDGE_CRON_SECRET") ?? "";
  if (!secret) return false;
  const auth = req.headers.get("Authorization") ?? "";
  return auth === `Bearer ${secret}`;
}

function cursorToPgTimestamp(cursor: string): string {
  return cursor.replace("T", " ").replace("Z", "").slice(0, 19);
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405);
  if (!authorize(req)) return json({ ok: false, error: "unauthorized" }, 401);

  const bridgeEnabled = Deno.env.get("BRIDGE_ENABLED") === "true";
  const body = (await req.json().catch(() => ({}))) as BridgeRequest;
  const dryRun = body.dry_run === true;

  if (!bridgeEnabled && !dryRun) {
    return json({ ok: false, error: "bridge disabled (set BRIDGE_ENABLED=true)" }, 503);
  }

  const batchLimit = Math.min(Math.max(body.limit ?? Number(Deno.env.get("BRIDGE_BATCH_LIMIT") ?? "50"), 1), 500);
  const tableName = Deno.env.get("ERP_WHATSAPP_MESSAGES_TABLE") ?? "whatsapp_messages";

  const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
  const admin = createClient(supabaseUrl, serviceKey);

  const { data: stateRow, error: stateError } = await admin
    .from("whatsapp_studio_inbox_bridge_state")
    .select("*")
    .eq("id", 1)
    .maybeSingle();

  if (stateError) return json({ ok: false, error: stateError.message }, 500);

  const cursorBefore = body.cursor_override ?? stateRow?.last_erp_cursor ?? "1970-01-01T00:00:00Z";
  const cursorPg = cursorToPgTimestamp(cursorBefore);

  const { data: erpRows, error: readError } = await admin
    .from(tableName)
    .select(
      "id, contact_id, direction, message_type, content, provider_message_id, provider, status, message_timestamp, created_at, whatsapp_contacts!inner(phone_number, customer_name)",
    )
    .eq("direction", "inbound")
    .gt("message_timestamp", cursorPg)
    .order("message_timestamp", { ascending: true })
    .order("id", { ascending: true })
    .limit(batchLimit);

  if (readError) return json({ ok: false, error: readError.message }, 500);

  const rows = (erpRows ?? []) as ErpWhatsAppMessageRow[];
  const runId = crypto.randomUUID();
  const preview: Record<string, unknown>[] = [];
  const errors: BridgeRunError[] = [];

  let ingested = 0;
  let duplicates = 0;
  let skipped = 0;
  let failed = 0;
  let cursorAfter = cursorBefore;
  let lastRowId: string | null = stateRow?.last_erp_row_id ?? null;

  if (dryRun) {
    for (const row of rows) {
      const mapped = mapErpWhatsAppMessage(row);
      if (!mapped.ok) {
        preview.push({ erp_row_id: row.id, error: mapped.error });
        continue;
      }
      if ("skipped" in mapped && mapped.skipped) {
        preview.push({ erp_row_id: row.id, skipped: true, reason: mapped.reason });
        continue;
      }
      preview.push({
        erp_row_id: row.id,
        provider_message_id: mapped.value.provider_message_id,
        sender_phone: mapped.value.sender_phone,
        message_body: mapped.value.message_body,
        received_at: mapped.value.received_at,
      });
    }

    return json({
      ok: true,
      dry_run: true,
      run_id: runId,
      cursor_before: cursorBefore,
      rows_read: rows.length,
      preview,
    });
  }

  for (const row of rows) {
    const mapped = mapErpWhatsAppMessage(row);
    const providerId = mapped.ok && !("skipped" in mapped && mapped.skipped)
      ? mapped.value.provider_message_id
      : null;

    const result = await processErpInboundRow(row, {
      resolve: async (messageBody) => resolveInboundAtEdge(admin, messageBody),
      rpc: async (fn, args) => {
        let duplicate = false;
        if (providerId) {
          const { data: existing } = await admin
            .from("whatsapp_inbound_messages")
            .select("id")
            .eq("provider_message_id", providerId)
            .maybeSingle();
          duplicate = Boolean(existing);
        }
        const { data, error } = await admin.rpc(fn, args);
        return {
          data: data ? { ...(data as Record<string, unknown>), __ingest_duplicate: duplicate } : null,
          error,
        };
      },
    });

    const rowTs = erpTimestampToIso(row.message_timestamp ?? row.created_at);

    if (!result.ok) {
      failed += 1;
      errors.push({ erp_row_id: row.id, error: result.error });
      continue;
    }

    if ("skipped" in result && result.skipped) {
      skipped += 1;
      continue;
    }

    if (result.duplicate) {
      duplicates += 1;
      if (rowTs >= cursorAfter) {
        cursorAfter = rowTs;
        lastRowId = row.id;
      }
      continue;
    }

    ingested += 1;
    if (rowTs >= cursorAfter) {
      cursorAfter = rowTs;
      lastRowId = row.id;
    }
  }

  const { error: updateError } = await admin
    .from("whatsapp_studio_inbox_bridge_state")
    .update({
      last_erp_cursor: cursorAfter,
      last_erp_row_id: lastRowId,
      last_run_at: new Date().toISOString(),
      last_run_rows_read: rows.length,
      last_run_rows_ingested: ingested,
      last_run_rows_duplicate: duplicates,
      last_run_rows_skipped: skipped,
      last_run_rows_failed: failed,
      last_error: errors[0]?.error ?? null,
      last_run_errors: errors.length ? errors : null,
      updated_at: new Date().toISOString(),
    })
    .eq("id", 1);

  if (updateError) return json({ ok: false, error: updateError.message }, 500);

  return json({
    ok: true,
    run_id: runId,
    cursor_before: cursorBefore,
    cursor_after: cursorAfter,
    rows_read: rows.length,
    rows_ingested: ingested,
    rows_duplicate: duplicates,
    rows_skipped: skipped,
    rows_failed: failed,
    errors,
  });
});
