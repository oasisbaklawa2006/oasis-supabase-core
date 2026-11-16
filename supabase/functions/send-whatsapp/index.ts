import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.0";
import { requireInternalStaff } from "../_shared/requireInternalStaff.ts";
import { selectClick2ApiProviderMessageId } from "../_shared/whatsappProviderAcceptance.ts";

const PORTAL_URL = Deno.env.get("B2B_PORTAL_URL") ||
  "https://b2b.oasisbaklawa.com";
const CTA_FOOTER =
  `\n\nPlease login to your B2B Portal to track your 10-point artisan journey:\n${PORTAL_URL}`;
const MAX_MESSAGE_LENGTH = 4_000;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const CLICK2API_SEND_ENDPOINT = "https://crm.click2api.in/api/v1/messages";

type SendResult = {
  success: boolean;
  provider: string;
  messageId?: string;
  error?: string;
  status?: number;
  acceptanceUnknown?: boolean;
};

type SendPayload = {
  to?: unknown;
  message?: unknown;
  company_id?: unknown;
  order_id?: unknown;
};

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizePhone(value: string): string | null {
  const digits = value.replace(/[^0-9]/g, "");
  const normalized = digits.length === 10 ? `91${digits}` : digits;
  return normalized.length >= 10 && normalized.length <= 15 ? normalized : null;
}

/**
 * Compatibility send: exactly one Click2API attempt. Never cross-provider
 * fallback or claim delivered. Unknown transport acceptance is quarantined.
 * Durable duplicate prevention at the caller remains a separate release gate.
 */
export async function sendViaClick2API(
  phone: string,
  fullMessage: string,
  fetcher: (url: string, init: RequestInit) => Promise<Response> = fetch,
): Promise<SendResult> {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  if (!apiKey) {
    return {
      success: false,
      provider: "click2api",
      error: "PROVIDER_NOT_CONFIGURED",
    };
  }

  try {
    const response = await fetcher(CLICK2API_SEND_ENDPOINT, {
      method: "POST",
      // Never forward provider credentials to an untrusted redirect target.
      redirect: "manual",
      signal: AbortSignal.timeout(20_000),
      headers: {
        "Content-Type": "application/json",
        apikey: apiKey,
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to: phone,
        type: "text",
        text: { body: fullMessage },
      }),
    });
    const data = await response.json().catch(() => ({}));
    if (
      !response.ok || data?.success === false ||
      data?.response?.success === false
    ) {
      return {
        success: false,
        provider: "click2api",
        error: `HTTP_${response.status}_REJECTED`,
        status: response.status,
      };
    }

    const messages = Array.isArray(data?.messages)
      ? data.messages
      : Array.isArray(data?.response?.messages)
      ? data.response.messages
      : [];
    if (
      messages.some(
        (item: { message_status?: unknown }) =>
          ["failed", "rejected", "undelivered"].includes(
            String(item?.message_status ?? "").toLowerCase(),
          ),
      )
    ) {
      return {
        success: false,
        provider: "click2api",
        error: "PROVIDER_MESSAGE_REJECTED",
        status: response.status,
      };
    }
    const canonicalId = messages.find(
      (item: { id?: unknown; message_status?: unknown }) =>
        typeof item?.id === "string" &&
        item.id.startsWith("wamid.") &&
        !["failed", "rejected"].includes(
          String(item.message_status ?? "").toLowerCase(),
        ),
    )?.id;
    const providerId = canonicalId || selectClick2ApiProviderMessageId(data);
    if (providerId == null) {
      return {
        success: false,
        acceptanceUnknown: true,
        provider: "click2api",
        error: "ACCEPTANCE_UNKNOWN",
        status: response.status,
      };
    }
    return {
      success: true,
      provider: "click2api",
      messageId: String(providerId),
      status: response.status,
    };
  } catch {
    return {
      success: false,
      acceptanceUnknown: true,
      provider: "click2api",
      error: "ACCEPTANCE_UNKNOWN",
    };
  }
}

if (import.meta.main) {
  serve(async (req) => {
    if (req.method === "OPTIONS") {
      return new Response(null, { headers: corsHeaders });
    }
    if (req.method !== "POST") {
      return json({ error: "Method not allowed" }, 405);
    }

    const authorization = await requireInternalStaff(req);
    if (!authorization.ok) {
      return json({ error: authorization.error }, authorization.status);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL");
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!supabaseUrl || !serviceRoleKey) {
      return json({ error: "Supabase service is not configured" }, 500);
    }

    try {
      const payload = (await req.json()) as SendPayload;
      if (
        typeof payload.to !== "string" || typeof payload.message !== "string"
      ) {
        return json({ error: "to and message are required" }, 400);
      }

      const message = payload.message.trim();
      const fullMessage = message + CTA_FOOTER;
      const apiPhone = normalizePhone(payload.to);
      if (!apiPhone || !message || fullMessage.length > MAX_MESSAGE_LENGTH) {
        return json({ error: "Invalid phone number or message" }, 400);
      }

      const companyId = typeof payload.company_id === "string"
        ? payload.company_id
        : null;
      const orderId = typeof payload.order_id === "string"
        ? payload.order_id
        : null;
      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false },
      });

      const result = await sendViaClick2API(apiPhone, fullMessage);
      await supabaseAdmin.from("debug_webhooks").insert({
        direction: "outbound",
        raw_payload: {
          provider: result.provider,
          accepted: result.success,
          acceptance_unknown: result.acceptanceUnknown === true,
          status_code: result.status ?? null,
          caller_kind: authorization.caller.kind,
        },
        phone_number: null,
        error_message: result.success ? null : result.error,
        processed: result.success,
      });

      if (!result.success) {
        await supabaseAdmin.from("audit_logs").insert({
          action_type: "whatsapp_api_error",
          module_name: "whatsapp",
          entity_name: "send-whatsapp",
          entity_id: orderId,
          risk_level: "high",
          reason: result.acceptanceUnknown
            ? "Click2API acceptance unconfirmed"
            : "Click2API rejected outbound message",
          new_value: {
            provider: result.provider,
            status: result.status ?? null,
            error_code: result.error ?? null,
            acceptance_unknown: result.acceptanceUnknown === true,
          },
        });
      }

      if (companyId) {
        const { error: timelineError } = await supabaseAdmin
          .from("client_interactions").insert({
            company_id: companyId,
            executive_id: authorization.caller.userId,
            interaction_type: "whatsapp",
            notes: "[WhatsApp outbound event; contents omitted from timeline]",
            outcome: result.success
              ? "sent"
              : result.acceptanceUnknown
              ? "pending"
              : "failed",
          });
        if (timelineError) {
          console.warn(
            "[send-whatsapp] CRM timeline insert failed",
            timelineError.code ?? "UNKNOWN",
          );
        }
      }

      if (orderId) {
        try {
          let contact = await supabaseAdmin
            .from("whatsapp_contacts")
            .select("id")
            .eq("phone_number", apiPhone)
            .maybeSingle();
          if (!contact.data) {
            contact = await supabaseAdmin
              .from("whatsapp_contacts")
              .insert({ phone_number: apiPhone, wa_contact_id: apiPhone })
              .select("id")
              .single();
          }
          if (contact.data?.id) {
            await supabaseAdmin.from("whatsapp_messages").insert({
              contact_id: contact.data.id,
              order_id: orderId,
              direction: "outbound",
              message_type: "text",
              content: message,
              provider: result.provider,
              provider_message_id: result.messageId || null,
              status: result.success
                ? "sent"
                : result.acceptanceUnknown
                ? "pending"
                : "failed",
              retry_count: 0,
              failure_reason: result.error || null,
            });
          }
        } catch (error) {
          console.warn(
            "[send-whatsapp] outbound ledger write unavailable",
            error instanceof Error ? error.name : "unknown",
          );
        }
      }

      if (!result.success) {
        if (result.acceptanceUnknown === true) {
          return json({
            success: false,
            acceptance_unknown: true,
            error: "ACCEPTANCE_UNKNOWN",
          }, 202);
        }
        return json(
          {
            success: false,
            error: result.error || "PROVIDER_SEND_REJECTED",
            provider: result.provider,
            status: result.status,
          },
          result.status && result.status >= 400 ? result.status : 502,
        );
      }

      return json(
        {
          success: true,
          provider: result.provider,
          messageId: result.messageId,
        },
        200,
      );
    } catch (error) {
      console.error(
        "[send-whatsapp] fatal error:",
        error instanceof Error ? error.name : "unexpected",
      );
      return json({ error: "Unable to send WhatsApp message" }, 500);
    }
  });
}
