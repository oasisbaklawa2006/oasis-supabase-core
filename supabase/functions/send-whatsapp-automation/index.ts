// supabase/functions/send-whatsapp-automation/index.ts
// Trigger WhatsApp notifications for order lifecycle events

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.45.0";
import { requireInternalStaff } from "../_shared/requireInternalStaff.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

type AutomationPayload = {
  orderId?: unknown;
  triggerType?: unknown;
};

type TriggerType =
  | "so_created"
  | "payment_verified"
  | "production_started"
  | "order_dispatched";

const ALLOWED_TRIGGERS = new Set<TriggerType>([
  "so_created",
  "payment_verified",
  "production_started",
  "order_dispatched",
]);

const SEND_WHATSAPP_FUNCTION_URL = Deno.env.get("SEND_WHATSAPP_FUNCTION_URL") ||
  (Deno.env.get("SUPABASE_URL")
    ? `${Deno.env.get("SUPABASE_URL")}/functions/v1/send-whatsapp`
    : "");

function json(body: Record<string, unknown>, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

async function sendWhatsAppViaFunction(
  phone: string,
  message: string,
  orderId: string,
  companyId?: string,
): Promise<
  {
    success: boolean;
    acceptanceUnknown?: boolean;
    error?: string;
    messageId?: string;
  }
> {
  try {
    const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
    if (!serviceRoleKey || !SEND_WHATSAPP_FUNCTION_URL) {
      return { success: false, error: "Supabase service is not configured" };
    }

    const response = await fetch(SEND_WHATSAPP_FUNCTION_URL, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${serviceRoleKey}`,
        apikey: serviceRoleKey,
      },
      body: JSON.stringify({
        to: phone,
        message,
        order_id: orderId,
        company_id: companyId || null,
      }),
    });

    const data = await response.json().catch(() => ({}));
    return {
      success: response.ok && data?.success === true,
      messageId: data?.messageId,
      acceptanceUnknown: data?.acceptance_unknown === true,
      error: typeof data?.error === "string" ? data.error : "SEND_REJECTED",
    };
  } catch {
    return {
      success: false,
      acceptanceUnknown: true,
      error: "ACCEPTANCE_UNKNOWN",
    };
  }
}

type OrderNotificationData = {
  order_number?: string | number | null;
  customer_phone?: string | null;
  total_value?: string | number | null;
  advance_amount?: string | number | null;
  company_id?: string | null;
};

async function loadOrder(
  supabaseAdmin: SupabaseClient,
  orderId: string,
  fields: string,
): Promise<OrderNotificationData> {
  const { data, error } = await supabaseAdmin
    .from("orders")
    .select(fields)
    .eq("id", orderId)
    .single();
  if (error || !data) {
    throw new Error("WA100_AUTOMATION_ORDER_READ_UNAVAILABLE");
  }
  return data as unknown as OrderNotificationData;
}

/**
 * A single durable order+trigger claim is committed before any provider call.
 * Repeated calls, including failed/unknown outcomes, never send again.
 */
export async function dispatchOrderAutomation(
  admin: SupabaseClient,
  orderId: string,
  triggerType: TriggerType,
  template: string,
  phone: string,
  message: string,
  companyId?: string,
  sender: typeof sendWhatsAppViaFunction = sendWhatsAppViaFunction,
): Promise<void> {
  const digits = phone.replace(/[^0-9]/g, "");
  const normalizedPhone = digits.length === 10 ? `91${digits}` : digits;
  if (!/^[1-9][0-9]{9,14}$/.test(normalizedPhone)) {
    throw new Error("WA100_AUTOMATION_PHONE_INVALID");
  }
  const { data: claim, error: claimError } = await admin.rpc(
    "claim_legacy_whatsapp_automation_v1",
    {
      p_order_id: orderId,
      p_trigger_type: triggerType,
      p_phone_digits: normalizedPhone,
      p_template: template,
    },
  );
  if (claimError || !claim?.automation_id) {
    throw new Error("WA100_AUTOMATION_CLAIM_UNAVAILABLE");
  }
  if (claim.claimed !== true) {
    // An existing receipt always suppresses replay, whatever its status.
    return;
  }
  const result = await sender(
    normalizedPhone,
    message,
    orderId,
    companyId,
  );
  const status = result.success
    ? "sent"
    : result.acceptanceUnknown === true
    ? "acceptance_unknown"
    : "failed_final";
  const { error: updateError } = await admin.from("whatsapp_automations")
    .update({
      status,
      provider: "click2api",
      provider_message_id: result.messageId ?? null,
      failure_reason: result.success
        ? null
        : (result.error ?? "SEND_NOT_CONFIRMED"),
      sent_at: result.success ? new Date().toISOString() : null,
    })
    .eq("id", claim.automation_id)
    .eq("status", "pending");
  if (updateError) {
    // A failed ledger update cannot license another provider invocation.
    console.error(
      "[send-whatsapp-automation] claim update unavailable",
      updateError.code ?? "UNKNOWN",
    );
  }
}

async function handleSOCreated(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(
    supabaseAdmin,
    orderId,
    "order_number, customer_phone, total_value, advance_amount, company_id",
  );
  if (!order?.customer_phone) return;

  const message = `Hi! Your order SO-${order.order_number} has been created.
Amount: ₹${order.total_value}
Advance due: ₹${order.advance_amount}

Reply CONFIRM to proceed with payment.`;

  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "so_created",
    "so_confirmation",
    order.customer_phone,
    message,
    order.company_id ?? undefined,
  );
}

async function handlePaymentVerified(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(
    supabaseAdmin,
    orderId,
    "order_number, customer_phone, company_id",
  );
  if (!order?.customer_phone) return;

  const message = `✓ Payment verified for SO-${order.order_number}
Your order is now in production. We'll update you soon!`;
  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "payment_verified",
    "payment_confirmed",
    order.customer_phone,
    message,
    order.company_id ?? undefined,
  );
}

async function handleProductionStarted(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(
    supabaseAdmin,
    orderId,
    "order_number, customer_phone, company_id",
  );
  if (!order?.customer_phone) return;

  const message = `🏭 Production started for SO-${order.order_number}
Expected completion in 2-3 days. We'll keep you updated!`;
  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "production_started",
    "production_alert",
    order.customer_phone,
    message,
    order.company_id ?? undefined,
  );
}

async function handleOrderDispatched(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(
    supabaseAdmin,
    orderId,
    "order_number, customer_phone, company_id",
  );
  if (!order?.customer_phone) return;

  const message = `📦 Your order SO-${order.order_number} is on the way!
Track updates on our app or reply here for support.`;
  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "order_dispatched",
    "dispatch_alert",
    order.customer_phone,
    message,
    order.company_id ?? undefined,
  );
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
    if (authorization.caller.kind !== "service_role") {
      return json({ error: "Service-role invocation is required" }, 403);
    }

    try {
      const payload = (await req.json()) as AutomationPayload;
      if (
        typeof payload.orderId !== "string" ||
        typeof payload.triggerType !== "string" ||
        !ALLOWED_TRIGGERS.has(payload.triggerType as TriggerType)
      ) {
        return json(
          { error: "Valid orderId and triggerType are required" },
          400,
        );
      }

      const supabaseUrl = Deno.env.get("SUPABASE_URL");
      const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
      if (!supabaseUrl || !serviceRoleKey) {
        return json({ error: "Supabase service is not configured" }, 500);
      }

      const supabaseAdmin = createClient(supabaseUrl, serviceRoleKey, {
        auth: { persistSession: false },
      });
      const triggerType = payload.triggerType as TriggerType;

      switch (triggerType) {
        case "so_created":
          await handleSOCreated(supabaseAdmin, payload.orderId);
          break;
        case "payment_verified":
          await handlePaymentVerified(supabaseAdmin, payload.orderId);
          break;
        case "production_started":
          await handleProductionStarted(supabaseAdmin, payload.orderId);
          break;
        case "order_dispatched":
          await handleOrderDispatched(supabaseAdmin, payload.orderId);
          break;
      }

      return json({
        success: true,
        trigger: triggerType,
        orderId: payload.orderId,
      }, 200);
    } catch (error) {
      console.error(
        "[send-whatsapp-automation] error:",
        error instanceof Error ? error.name : "unknown",
      );
      return json({ error: "Unable to process WhatsApp automation" }, 500);
    }
  });
}
