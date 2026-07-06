import { corsHeaders } from "npm:@supabase/supabase-js@2.95.0/cors";
import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { verifyMetaWebhookSignature } from "../_shared/metaSignature.ts";
import { resolveInboundAtEdge } from "../_shared/resolveInboundAtEdge.ts";

/**
 * Phase 2F — Meta WhatsApp webhook with signature verification and edge resolver ingest.
 * Draft-only path — no orders, stock, finance, dispatch, or outbound replies.
 */

type WebhookBody = {
  provider?: "meta_whatsapp" | "test";
  provider_message_id?: string | null;
  sender_phone?: string;
  sender_name?: string | null;
  message_body?: string | null;
  message_type?: string | null;
  received_at?: string | null;
  raw_payload?: Record<string, unknown> | null;
};

function extractFromMeta(raw: Record<string, unknown>) {
  const entry = (raw.entry as unknown[])?.[0] as Record<string, unknown> | undefined;
  const change = (entry?.changes as unknown[])?.[0] as Record<string, unknown> | undefined;
  const value = change?.value as Record<string, unknown> | undefined;
  const message = (value?.messages as unknown[])?.[0] as Record<string, unknown> | undefined;
  const contact = (value?.contacts as unknown[])?.[0] as Record<string, unknown> | undefined;
  return {
    provider_message_id: message?.id ? String(message.id) : null,
    sender_phone: message?.from ? String(message.from) : null,
    sender_name: (contact?.profile as { name?: string } | undefined)?.name ?? null,
    message_body: (message?.text as { body?: string } | undefined)?.body ?? null,
    message_type: message?.type ? String(message.type) : "text",
    received_at: message?.timestamp
      ? new Date(Number(message.timestamp) * 1000).toISOString()
      : new Date().toISOString(),
  };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });

  const url = new URL(req.url);
  if (req.method === "GET") {
    const mode = url.searchParams.get("hub.mode");
    const token = url.searchParams.get("hub.verify_token");
    const challenge = url.searchParams.get("hub.challenge");
    const verifyToken = Deno.env.get("WHATSAPP_WEBHOOK_VERIFY_TOKEN") ?? "";
    if (mode === "subscribe" && token && token === verifyToken && challenge) {
      return new Response(challenge, { status: 200, headers: corsHeaders });
    }
    return json({ ok: false, error: "invalid verification request" }, 403);
  }

  if (req.method !== "POST") {
    return json({ ok: false, error: "method not allowed" }, 405);
  }

  try {
    const rawBody = await req.text();
    const body = (JSON.parse(rawBody || "{}") || {}) as WebhookBody | Record<string, unknown>;
    const provider =
      (body as WebhookBody).provider ??
      ((body as Record<string, unknown>).entry ? "meta_whatsapp" : "test");

    const appSecret = Deno.env.get("WHATSAPP_APP_SECRET") ?? "";
    const allowTestWebhook = Deno.env.get("ALLOW_TEST_WEBHOOK") === "true";

    if (provider === "meta_whatsapp") {
      if (!appSecret) {
        return json({ ok: false, error: "WHATSAPP_APP_SECRET is not configured" }, 503);
      }
      const signature = req.headers.get("x-hub-signature-256");
      const valid = await verifyMetaWebhookSignature(rawBody, signature, appSecret);
      if (!valid) {
        return json({ ok: false, error: "invalid webhook signature" }, 401);
      }
    } else if (!allowTestWebhook) {
      return json({ ok: false, error: "test webhook provider is disabled" }, 403);
    }

    const raw_payload = ((body as WebhookBody).raw_payload ?? body) as Record<string, unknown>;
    const meta = provider === "meta_whatsapp" ? extractFromMeta(raw_payload) : null;

    const sender_phone = String((body as WebhookBody).sender_phone ?? meta?.sender_phone ?? "").trim();
    const message_body = String((body as WebhookBody).message_body ?? meta?.message_body ?? "").trim();
    const message_type = String((body as WebhookBody).message_type ?? meta?.message_type ?? "text");

    if (!sender_phone) return json({ ok: false, error: "sender_phone is required" }, 400);
    if (message_type !== "text" && message_type !== "interactive" && message_type !== "button") {
      return json({ ok: true, ignored: true, reason: `unsupported message type: ${message_type}` }, 200);
    }
    if (!message_body) return json({ ok: false, error: "message_body is required for text messages" }, 400);

    const supabaseUrl = Deno.env.get("SUPABASE_URL")!;
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const admin = createClient(supabaseUrl, serviceKey);

    const resolved = await resolveInboundAtEdge(admin, message_body);

    const { data, error } = await admin.rpc("ingest_whatsapp_inbound_message", {
      _provider_message_id: (body as WebhookBody).provider_message_id ?? meta?.provider_message_id,
      _sender_phone: sender_phone,
      _sender_name: (body as WebhookBody).sender_name ?? meta?.sender_name,
      _message_body: message_body,
      _message_type: message_type,
      _received_at: (body as WebhookBody).received_at ?? meta?.received_at,
      _raw_payload: { ...raw_payload, webhook_provider: provider },
      _resolver_status: resolved.resolver_status,
      _resolver_result_json: resolved.resolver_result_json,
    });

    if (error) return json({ ok: false, error: error.message }, 500);

    return json({
      ok: true,
      message_id: data?.id,
      resolver_status: data?.resolver_status ?? resolved.resolver_status,
      order_quantity: resolved.resolver_result_json?.order_quantity ?? 1,
    }, 200);
  } catch (e) {
    return json({ ok: false, error: (e as Error).message }, 500);
  }
});

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
