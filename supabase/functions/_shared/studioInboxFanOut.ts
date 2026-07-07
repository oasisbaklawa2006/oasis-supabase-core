import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { resolveInboundAtEdge } from "./resolveInboundAtEdge.ts";

export type StudioFanOutInput = {
  supabaseAdmin: SupabaseClient;
  providerMessageId: string;
  senderPhone: string;
  senderName: string | null;
  messageBody: string;
  rawPayload: Record<string, unknown>;
  timestampSec: number | string | null;
};

/** Read-only Studio inbox ingest — must never throw to caller (legacy ERP path). */
export async function fanOutToStudioInbox(input: StudioFanOutInput): Promise<void> {
  const trimmedBody = input.messageBody.trim();
  if (!trimmedBody || !input.providerMessageId) return;

  let resolver_status: "resolved" | "pending" | "failed" = "pending";
  let resolver_result_json: Record<string, unknown> | null = null;

  try {
    const resolved = await resolveInboundAtEdge(input.supabaseAdmin, trimmedBody);
    if (resolved.resolver_status === "resolved" && resolved.resolver_result_json) {
      resolver_status = "resolved";
      resolver_result_json = resolved.resolver_result_json as unknown as Record<string, unknown>;
    }
  } catch (e) {
    console.warn("[studio-fanout] resolver skipped:", e);
  }

  const tsSec =
    input.timestampSec != null && input.timestampSec !== "" ? Number(input.timestampSec) : NaN;
  const receivedAt =
    Number.isFinite(tsSec) && tsSec > 0 ? new Date(tsSec * 1000).toISOString() : new Date().toISOString();

  const { error } = await input.supabaseAdmin.rpc("ingest_whatsapp_inbound_message", {
    _provider_message_id: input.providerMessageId,
    _sender_phone: input.senderPhone,
    _sender_name: input.senderName,
    _message_body: trimmedBody,
    _message_type: "text",
    _received_at: receivedAt,
    _raw_payload: {
      ...input.rawPayload,
      studio_fanout: true,
      studio_fanout_source: "whatsapp-webhook-legacy",
    },
    _resolver_status: resolver_status,
    _resolver_result_json: resolver_result_json,
  });

  if (error) {
    console.warn("[studio-fanout] ingest_whatsapp_inbound_message failed:", error.message);
  }
}
