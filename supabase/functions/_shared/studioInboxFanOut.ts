import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { resolveInboundAtEdge } from "./resolveInboundAtEdge.ts";

export type StudioFanOutInput = {
  supabaseAdmin: SupabaseClient;
  providerMessageId: string;
  senderPhone: string;
  senderName: string | null;
  messageBody: string;
  messageType?: string;
  mediaCount?: number;
  conversationKey?: string | null;
  correctionOfProviderMessageId?: string | null;
  rawPayload: Record<string, unknown>;
  timestampSec: number | string | null;
  orderLikeHint: boolean;
  commercialRiskReason: string | null;
};

/**
 * Durable Studio/WA-1 ingest. Commercial-risk capture failures must reach the
 * webhook caller so the provider can retry; non-commercial fan-out remains best effort.
 */
export async function fanOutToStudioInbox(input: StudioFanOutInput): Promise<void> {
  const trimmedBody = input.messageBody.trim() || `[unreadable ${input.messageType || "media"} attachment]`;
  if (!input.providerMessageId) {
    if (input.orderLikeHint) throw new Error("commercial WhatsApp message is missing provider message id");
    return;
  }

  let resolver_status: "resolved" | "pending" | "failed" = "pending";
  let resolver_result_json: Record<string, unknown> | null = null;

  try {
    const resolved = await resolveInboundAtEdge(input.supabaseAdmin, trimmedBody);
    if (resolved.resolver_status === "resolved" && resolved.resolver_result_json) {
      resolver_status = "resolved";
      resolver_result_json = resolved.resolver_result_json as unknown as Record<string, unknown>;
    } else if (resolved.resolver_status === "failed") {
      resolver_status = "failed";
    }
  } catch (e) {
    console.warn("[studio-fanout] resolver skipped:", e);
  }

  const tsSec =
    input.timestampSec != null && input.timestampSec !== "" ? Number(input.timestampSec) : NaN;
  const receivedAt =
    Number.isFinite(tsSec) && tsSec > 0 ? new Date(tsSec * 1000).toISOString() : new Date().toISOString();

  const { data: inbound, error } = await input.supabaseAdmin.rpc("ingest_whatsapp_inbound_message", {
    _provider_message_id: input.providerMessageId,
    _sender_phone: input.senderPhone,
    _sender_name: input.senderName,
    _message_body: trimmedBody,
    _message_type: input.messageType || "text",
    _received_at: receivedAt,
    _raw_payload: {
      ...input.rawPayload,
      studio_fanout: true,
      studio_fanout_source: "whatsapp-webhook-legacy",
      commercial_eligible: input.orderLikeHint,
      commercial_risk_reason: input.commercialRiskReason,
    },
    _resolver_status: resolver_status,
    _resolver_result_json: resolver_result_json,
  });

  if (error) {
    console.warn("[studio-fanout] ingest_whatsapp_inbound_message failed:", error.message);
    if (input.orderLikeHint) throw new Error(`commercial WhatsApp ingest failed: ${error.message}`);
    return;
  }

  const inboundRow = Array.isArray(inbound) ? inbound[0] : inbound;
  if (input.orderLikeHint && !inboundRow?.id) {
    throw new Error("commercial WhatsApp ingest returned no inbound message id");
  }
  if (inboundRow?.id && input.orderLikeHint) {
    const mediaCount = Math.max(0, input.mediaCount ?? 0);
    const unreadableMedia =
      !input.messageBody.trim() && (input.messageType || "text") !== "text";
    const resolvedWithoutProduct =
      resolver_status === "resolved" && !resolver_result_json?.resolved_product_id;
    // Empty-body multimodal ingress is AWAITING_MEDIA until download/worker
    // completes. Do not terminalize as FAILED_INTERPRETATION at capture.
    const interpretationFailed =
      resolvedWithoutProduct || (unreadableMedia && mediaCount === 0);
    const awaitingMediaReview = unreadableMedia && mediaCount > 0;
    let correctionSourceId: string | null = null;
    if (input.correctionOfProviderMessageId) {
      const correctionSource = await input.supabaseAdmin
        .from("whatsapp_inbound_messages")
        .select("id")
        .eq("provider_message_id", input.correctionOfProviderMessageId)
        .maybeSingle();
      correctionSourceId = correctionSource.data?.id ?? null;
    }
    const { error: captureError } = await input.supabaseAdmin.rpc("capture_whatsapp_commercial_fragment", {
      p_source_message_id: inboundRow.id,
      p_packet_id: null,
      p_conversation_key: input.conversationKey,
      p_correction_of_source_message_id: correctionSourceId,
      p_media_count: mediaCount,
      p_interpretation_failed: interpretationFailed,
      p_evidence: {
        ingress: "whatsapp-webhook",
        resolver_status,
        commercial_risk_reason: input.commercialRiskReason,
        fail_open_media_review: awaitingMediaReview ? true : undefined,
        interpretation_failure_kind: interpretationFailed
          ? unreadableMedia
            ? "UNREADABLE_MEDIA"
            : resolvedWithoutProduct
            ? "UNRESOLVED_PRODUCT"
            : null
          : awaitingMediaReview
          ? "AWAITING_MEDIA_REVIEW"
          : null,
      },
    });
    if (captureError) {
      console.warn("[studio-fanout] potential-order capture failed:", captureError.message);
      throw new Error(`commercial potential-order capture failed: ${captureError.message}`);
    }
  }
}
