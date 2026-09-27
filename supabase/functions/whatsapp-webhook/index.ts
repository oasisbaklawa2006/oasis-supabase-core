/* eslint-disable @typescript-eslint/no-explicit-any -- Click2API/Meta webhook payloads are untrusted multi-shape provider input normalized immediately by extractPayloadFields. */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import { authenticateClick2ApiWebhook, matchesWebhookToken } from "../_shared/click2apiWebhookAuth.ts";
import { extractProviderStatusEvents, persistOperatorReplyProviderStatus } from "../_shared/whatsappOperatorReplyStatus.ts";

type SupabaseAdminClient = SupabaseClient;
type EdgeRuntimeWithWaitUntil = { waitUntil?: (promise: Promise<unknown>) => void };

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
  "Content-Type": "application/json",
};

const ORDER_INTENT_KEYWORDS = [
  "need", "order", "send", "want", "box", "boxes", "carton", "cartons",
  "kg", "pcs", "pieces", "rate", "price", "quote",
];
const DEVANAGARI_COMMERCE = /(किलो|केजी|किग्रा|बॉक्स|डिब्ब|कार्टन|पीस|ऑर्डर|भेज|डालना|चाहिए|मंगवा|मंगाना)/u;
const MEDIA_MESSAGE_TYPES = new Set(["image", "document", "video", "audio"]);

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

function to91(raw: string): string {
  const digits = raw.replace(/[^0-9]/g, "");
  if (digits.length === 10) return `91${digits}`;
  if (digits.length === 12 && digits.startsWith("91")) return digits;
  return digits;
}

function stringBody(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function extractPayloadFields(payload: any) {
  const value = payload?.entry?.[0]?.changes?.[0]?.value;
  if (value) {
    const msg = value?.messages?.[0];
    const contact = value?.contacts?.[0];
    const media = msg?.image ?? msg?.document ?? msg?.video ?? msg?.audio ?? null;
    return {
      senderPhone: msg?.from || contact?.wa_id || "",
      messageBody: msg?.text?.body || msg?.caption || media?.caption || "",
      messageType: msg?.type || "text",
      mediaUrl: media?.url || media?.link || null,
      mediaId: media?.id || null,
      messageId: msg?.id || null,
      profileName: contact?.profile?.name || null,
      timestampSec: msg?.timestamp ?? null,
      statuses: Array.isArray(value?.statuses) ? value.statuses : [],
    };
  }

  const m91 = payload?.payload?.message
    ? payload.payload
    : payload?.data?.payload?.message
    ? payload.data.payload
    : null;
  if (m91) {
    const message = m91.message || {};
    const media = message.media || message.image || message.document || message.video || message.audio || null;
    const inferredMediaType = message.audio
      ? "audio"
      : message.video
      ? "video"
      : message.document
      ? "document"
      : message.image
      ? "image"
      : media
      ? "image"
      : "text";
    const text = message.text?.body || message.text || message.caption || media?.caption || m91.text || "";
    return {
      senderPhone: m91.mobile || m91.from || m91.sender || m91.contact?.wa_id || "",
      messageBody: typeof text === "string" ? text : (text?.body || ""),
      messageType: message.type || m91.type || inferredMediaType,
      mediaUrl: media?.url || media?.link || media?.media_url || null,
      mediaId: media?.id || media?.media_id || null,
      messageId: m91._id || m91.id || m91.message_id || message.id || null,
      profileName: m91.sender_name || m91.name || m91.contact?.profile?.name || null,
      timestampSec: m91.timestamp ?? message.timestamp ?? null,
      statuses: [],
    };
  }

  const fallbackType = payload?.messageType || payload?.type || payload?.data?.type || "text";
  return {
    senderPhone: payload?.from || payload?.sender || payload?.mobile || payload?.data?.from || payload?.contact?.wa_id || payload?.waId || "",
    messageBody: stringBody(payload?.message) || stringBody(payload?.body) || stringBody(payload?.data?.body) || stringBody(payload?.text?.body) || stringBody(payload?.text),
    messageType: fallbackType,
    mediaUrl:
      payload?.mediaUrl || payload?.media_url || payload?.data?.media_url ||
      payload?.image?.url || payload?.document?.url || payload?.video?.url || payload?.audio?.url ||
      payload?.data?.image?.url || payload?.data?.document?.url || payload?.data?.video?.url || payload?.data?.audio?.url || null,
    mediaId:
      payload?.mediaId || payload?.media_id || payload?.image?.id || payload?.document?.id || payload?.video?.id || payload?.audio?.id || payload?.data?.media_id || null,
    messageId: payload?.messageId || payload?.id || payload?.message_id || null,
    profileName: payload?.pushName || payload?.profileName || payload?.contact?.name || payload?.sender_name || null,
    timestampSec: payload?.timestamp ?? payload?.data?.timestamp ?? null,
    statuses: Array.isArray(payload?.statuses) ? payload.statuses : [],
  };
}

function hasMediaEvidence(fields: { messageType: string; mediaUrl: string | null; mediaId: string | null }): boolean {
  return Boolean(fields.mediaUrl || fields.mediaId || MEDIA_MESSAGE_TYPES.has(String(fields.messageType || "").toLowerCase()));
}

function isPotentialCommercialIntake(messageBody: string, mediaEvidence: boolean): boolean {
  if (mediaEvidence) return true;
  const normalized = messageBody.toLowerCase();
  return ORDER_INTENT_KEYWORDS.some((keyword) => normalized.includes(keyword)) || DEVANAGARI_COMMERCE.test(messageBody);
}

async function ensureCorePotentialCapture(
  supabaseAdmin: SupabaseAdminClient,
  input: {
    providerMessageId: string;
    senderPhone: string;
    senderName: string;
    messageBody: string;
    messageType: string;
    receivedAt: string;
    rawPayload: unknown;
    orderLike: boolean;
  },
): Promise<void> {
  const { data: sourceMessage, error: sourceError } = await supabaseAdmin
    .from("whatsapp_inbound_messages")
    .upsert({
      provider_message_id: input.providerMessageId,
      sender_phone: input.senderPhone,
      sender_name: input.senderName || null,
      message_body: input.messageBody,
      message_type: input.messageType || "text",
      received_at: input.receivedAt,
      raw_payload: {
        ...(input.rawPayload && typeof input.rawPayload === "object" ? input.rawPayload : {}),
        commercial_eligible: input.orderLike,
      },
      resolver_status: "pending",
    }, { onConflict: "provider_message_id", ignoreDuplicates: true })
    .select("id")
    .maybeSingle();
  if (sourceError) throw new Error(`WA1_CORE_SOURCE_CAPTURE_FAILED: ${sourceError.message}`);

  let sourceMessageId = sourceMessage?.id;
  if (!sourceMessageId) {
    const { data: existing, error: existingError } = await supabaseAdmin
      .from("whatsapp_inbound_messages")
      .select("id")
      .eq("provider_message_id", input.providerMessageId)
      .single();
    if (existingError || !existing?.id) {
      throw new Error(`WA1_CORE_SOURCE_LOOKUP_FAILED: ${existingError?.message ?? "missing row"}`);
    }
    sourceMessageId = existing.id;
  }

  if (!input.orderLike) return;
  const { data: potentialOrder, error: captureError } = await supabaseAdmin.rpc("capture_whatsapp_potential_order", {
    p_source_message_id: sourceMessageId,
    p_order_like: true,
    p_interpretation_failed: false,
    p_evidence: { ingress: "click2api", authentication: "verified", capture_contract: "wa1", ingress_mode: "capture_only" },
  });
  if (captureError) throw new Error(`WA1_CORE_POTENTIAL_CAPTURE_FAILED: ${captureError.message}`);
  if (!potentialOrder?.id) throw new Error("WA1_CORE_POTENTIAL_CAPTURE_FAILED: missing authority row");

  const hasMedia = input.messageType.toLowerCase() !== "text";
  const { error: evidenceError } = await supabaseAdmin.rpc("capture_whatsapp_commercial_fragment_for_potential", {
    p_potential_order_id: potentialOrder.id,
    p_source_message_id: sourceMessageId,
    p_media_count: hasMedia ? 1 : 0,
    p_interpretation_failed: hasMedia,
    p_evidence: {
      ingress: "click2api",
      authentication: "verified",
      fail_open_media_review: hasMedia,
      ingress_mode: "capture_only",
    },
  });
  if (evidenceError) throw new Error(`WA4_CORE_EVIDENCE_CAPTURE_FAILED: ${evidenceError.message}`);
}

async function reconcileProviderStatuses(
  supabaseAdmin: SupabaseAdminClient,
  statuses: ReturnType<typeof extractProviderStatusEvents>,
): Promise<{ processed: number; matched: number; dispositions: string[] }> {
  let matched = 0;
  const dispositions: string[] = [];

  for (const statusEvent of statuses) {
    const result = await persistOperatorReplyProviderStatus(
      supabaseAdmin,
      statusEvent,
      "click2api",
    );
    dispositions.push(result.code);
    if (!result.ok) {
      throw new Error(
        `WHATSAPP_STATUS_PERSISTENCE_FAILED:${statusEvent.status}:${result.code}`,
      );
    }
    if (result.matched) matched += 1;
  }

  return { processed: statuses.length, matched, dispositions };
}

async function findOrCreateWhatsappContact(
  supabaseAdmin: SupabaseAdminClient,
  phoneDigits: string,
): Promise<string | null> {
  if (!phoneDigits) return null;
  const inserted = await supabaseAdmin
    .from("whatsapp_contacts")
    .upsert(
      { phone_number: phoneDigits },
      { onConflict: "phone_number" },
    )
    .select("id")
    .maybeSingle();
  if (inserted.data?.id) return inserted.data.id;

  const existing = await supabaseAdmin
    .from("whatsapp_contacts")
    .select("id")
    .eq("phone_number", phoneDigits)
    .maybeSingle();
  if (existing.data?.id) return existing.data.id;
  console.warn("[whatsapp-webhook] whatsapp_contacts insert failed", inserted.error?.message ?? existing.error?.message ?? "missing contact id");
  return null;
}

function triggerMessageStitcherNonBlocking(providerMessageId: string): void {
  const baseUrl = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!baseUrl || !serviceKey) return;
  const pending = fetch(`${baseUrl}/functions/v1/whatsapp-message-stitcher`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Authorization": `Bearer ${serviceKey}` },
    body: JSON.stringify({ trigger: "webhook", provider_message_id: providerMessageId }),
    signal: AbortSignal.timeout(10_000),
  }).catch((error) => console.warn("[whatsapp-webhook] stitcher call failed", String(error)));
  const edgeRuntime = (globalThis as typeof globalThis & { EdgeRuntime?: EdgeRuntimeWithWaitUntil }).EdgeRuntime;
  if (edgeRuntime?.waitUntil) edgeRuntime.waitUntil(pending);
  else void pending;
}

serve(async (req) => {
  if (req.method === "GET") {
    const url = new URL(req.url);
    const entries = Array.from(url.searchParams.entries());
    const challengeNames = ["challange", "challenge", "hub.challenge", "hub_challenge"];
    const tokenNames = ["echo", "hub.verify_token", "verify_token"];
    const challenge = entries.find(([key]) => challengeNames.includes(key.toLowerCase()));
    const token = entries.find(([key]) => tokenNames.includes(key.toLowerCase()));
    if (challenge && matchesWebhookToken(token?.[1] ?? null, Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN"))) {
      return new Response(challenge[1], { status: 200, headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }
    return new Response("Webhook verification failed", { status: 403 });
  }
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, error: "Method not allowed" }, 405);

  const auth = authenticateClick2ApiWebhook(
    req,
    Deno.env.get("WHATSAPP_WEBHOOK_SECRET"),
    Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN"),
  );
  if (!auth.authenticated) return json({ ok: false, error: "Unauthorized webhook" }, 401);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ ok: false, error: "Service configuration unavailable" }, 500);
  const admin = createClient(supabaseUrl, serviceKey);

  let payload: unknown;
  try {
    payload = await req.json();
  } catch {
    return json({ ok: false, error: "Malformed webhook payload" }, 400);
  }

  try {
    const fields = extractPayloadFields(payload);
    const mediaEvidence = hasMediaEvidence(fields);
    const providerStatuses = extractProviderStatusEvents(payload);

    if (providerStatuses.length > 0) {
      const reconciliation = await reconcileProviderStatuses(admin, providerStatuses);
      const { error: statusEvidenceError } = await admin.from("debug_webhooks").insert({
        direction: "inbound",
        raw_payload: payload,
        phone_number: fields.senderPhone ? to91(fields.senderPhone) : null,
        processed: true,
        discard_reason: "provider_status_evidence",
      });
      if (statusEvidenceError) {
        throw new Error(`WHATSAPP_STATUS_EVIDENCE_LOG_FAILED:${statusEvidenceError.message}`);
      }
      if (!fields.messageBody && !mediaEvidence) {
        return json({
          ok: true,
          captured: "provider_status_evidence",
          processed_statuses: reconciliation.processed,
          matched_statuses: reconciliation.matched,
          dispositions: reconciliation.dispositions,
        });
      }
    }

    const noiseTypes = new Set(["reaction", "unsupported", "system", "ephemeral", "sticker_reaction"]);
    const isNoise = noiseTypes.has(String(fields.messageType || "").toLowerCase());
    const isEmpty = !fields.messageBody && !mediaEvidence;
    if (isNoise || isEmpty) {
      await admin.from("debug_webhooks").insert({
        direction: "inbound",
        raw_payload: payload,
        phone_number: fields.senderPhone ? to91(fields.senderPhone) : null,
        wamid: fields.messageId || null,
        processed: true,
        discard_reason: isNoise ? `noise_${fields.messageType}` : "empty_body",
      });
      return json({ ok: true, discarded: isNoise ? fields.messageType : "empty" });
    }

    if (!fields.messageId) return json({ ok: false, error: "Provider message ID required" }, 400);

    const phone91 = to91(fields.senderPhone);
    const timestampSec = fields.timestampSec != null && fields.timestampSec !== ""
      ? Number(fields.timestampSec)
      : NaN;
    const timestampMs = timestampSec * 1000;
    const receivedAt = Number.isFinite(timestampMs) && timestampSec > 0 && timestampMs <= 8.64e15
      ? new Date(timestampMs).toISOString()
      : new Date().toISOString();
    const commercialEligible = isPotentialCommercialIntake(fields.messageBody || "", mediaEvidence);

    await ensureCorePotentialCapture(admin, {
      providerMessageId: fields.messageId,
      senderPhone: phone91,
      senderName: fields.profileName || "",
      messageBody: fields.messageBody || "",
      messageType: fields.messageType || "text",
      receivedAt,
      rawPayload: payload,
      orderLike: commercialEligible,
    });

    const { data: existingWamid } = await admin
      .from("debug_webhooks")
      .select("id")
      .eq("wamid", fields.messageId)
      .limit(1)
      .maybeSingle();
    const duplicateWamid = Boolean(existingWamid?.id);
    if (duplicateWamid) {
      await admin.from("debug_webhooks").insert({
        direction: "inbound",
        raw_payload: payload,
        phone_number: phone91 || null,
        wamid: fields.messageId,
        processed: true,
        discard_reason: "duplicate_wamid",
        error_message: `Duplicate WhatsApp message ID — original webhook ${existingWamid?.id}`,
      });
    } else {
      await admin.from("debug_webhooks").insert({
        direction: "inbound",
        raw_payload: payload,
        phone_number: phone91 || null,
        wamid: fields.messageId,
        processed: true,
        message_intent: commercialEligible ? "POTENTIAL_COMMERCIAL" : "OTHER",
      });
    }

    const contactId = await findOrCreateWhatsappContact(admin, phone91);
    if (!contactId) throw new Error("WHATSAPP_CONTACT_PERSISTENCE_FAILED");

    const { error: messageError } = await admin.from("whatsapp_messages").insert({
      contact_id: contactId,
      order_id: null,
      direction: "inbound",
      message_type: fields.messageType || "text",
      content: fields.messageBody || "",
      media_url: fields.mediaUrl || null,
      provider: "whatsapp",
      provider_message_id: fields.messageId,
      status: "received",
      message_timestamp: receivedAt,
      is_raw: true,
      packet_id: null,
    });
    const messageDuplicate = Boolean(messageError && String(messageError.message).toLowerCase().includes("duplicate"));
    if (messageError && !messageDuplicate) throw new Error(`WHATSAPP_MESSAGE_PERSISTENCE_FAILED: ${messageError.message}`);

    // Every delivery/retry re-kicks the idempotent packet pipeline using the
    // provider ID, allowing recovery even when the message is already stitched.
    triggerMessageStitcherNonBlocking(fields.messageId);

    return json({
      ok: true,
      capture_only: true,
      provider_message_id: fields.messageId,
      commercial_eligible: commercialEligible,
      duplicate_wamid: duplicateWamid,
      outbound_sent: false,
    });
  } catch (error) {
    const detail = error instanceof Error ? error.message : "Unexpected error";
    console.error("[whatsapp-webhook] capture failed", detail);
    return json({ ok: false, error: "Durable intake unavailable" }, 503);
  }
});
