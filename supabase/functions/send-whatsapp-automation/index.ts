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

/**
 * A service-role credential may be sent only to this project's exact named
 * function. Never accept an arbitrary external override or redirect target.
 */
export function resolveSafeSenderUrl(
  supabaseUrl: string | null,
  overrideUrl: string | null,
): string | null {
  if (!supabaseUrl) return null;
  try {
    const base = new URL(supabaseUrl);
    if (
      base.protocol !== "https:" ||
      base.username || base.password || base.search || base.hash ||
      base.pathname !== "/"
    ) return null;
    const target = new URL(
      overrideUrl ?? `${base.origin}/functions/v1/send-whatsapp`,
    );
    if (
      target.origin !== base.origin ||
      target.pathname !== "/functions/v1/send-whatsapp" ||
      target.username || target.password || target.search || target.hash
    ) return null;
    return target.toString();
  } catch {
    return null;
  }
}

const SEND_WHATSAPP_FUNCTION_URL = resolveSafeSenderUrl(
  Deno.env.get("SUPABASE_URL") ?? null,
  Deno.env.get("SEND_WHATSAPP_FUNCTION_URL") ?? null,
);

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
      // Disallow 3xx credential forwarding or cross-origin redirect chains.
      redirect: "manual",
      // Bound the internal Edge call independently of the provider timeout.
      signal: AbortSignal.timeout(25_000),
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
  sales_order_value?: string | number | null;
  advance_required?: string | number | null;
  company_id?: string | null;
};

/** Read only fields that exist in the governed Core public.orders schema. */
async function loadOrder(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<OrderNotificationData> {
  const { data, error } = await supabaseAdmin
    .from("orders")
    .select("order_number, sales_order_value, advance_required, company_id")
    .eq("id", orderId)
    .single();
  if (error || !data) {
    throw new Error("WA100_AUTOMATION_ORDER_READ_UNAVAILABLE");
  }
  return data as OrderNotificationData;
}

/**
 * Never infer the recipient from a company's generic phone field. For an
 * order-specific commercial disclosure, require a single time-valid
 * sales_order authorization, a confirmed company identity, and effective
 * transactional WhatsApp consent. Missing/ambiguous evidence fails closed.
 */
export async function resolveAuthorizedOrderRecipient(
  supabaseAdmin: SupabaseClient,
  companyId: string | null | undefined,
  now: Date = new Date(),
): Promise<string> {
  if (!companyId) {
    throw new Error("WA100_ORDER_COMPANY_NOT_VERIFIED");
  }
  const at = now.toISOString();
  const { data: authorities, error: authorityError } = await supabaseAdmin
    .from("whatsapp_sender_commercial_authorizations")
    .select("contact_id, disclosure_scope")
    .eq("company_id", companyId)
    .eq("status", "ACTIVE")
    .gt("valid_until", at);
  if (authorityError) {
    throw new Error("WA100_RECIPIENT_AUTHORITY_UNAVAILABLE");
  }
  const eligible = (authorities ?? []).filter(
    (a: { contact_id?: unknown; disclosure_scope?: unknown }) =>
      typeof a.contact_id === "string" &&
      Array.isArray(a.disclosure_scope) &&
      a.disclosure_scope.includes("sales_order"),
  );
  // Multiple matches may notify an unauthorized or unintended recipient.
  if (eligible.length !== 1) {
    throw new Error("WA100_RECIPIENT_AUTHORITY_MISSING_OR_AMBIGUOUS");
  }
  const { data: contact, error: contactError } = await supabaseAdmin
    .from("whatsapp_contacts")
    .select("phone_number")
    .eq("id", eligible[0].contact_id)
    .single();
  if (contactError || typeof contact?.phone_number !== "string") {
    throw new Error("WA100_AUTHORIZED_CONTACT_UNAVAILABLE");
  }
  const raw = contact.phone_number.replace(/[^0-9]/g, "");
  const digits = raw.length === 10 ? `91${raw}` : raw;
  if (!/^[1-9][0-9]{9,14}$/.test(digits)) {
    throw new Error("WA100_AUTHORIZED_PHONE_INVALID");
  }
  const { data: identities, error: identityError } = await supabaseAdmin
    .from("whatsapp_case_identities")
    .select("id")
    .eq("phone_e164", `+${digits}`)
    .eq("party_type", "COMPANY")
    .eq("party_id", companyId)
    .eq("resolution_status", "CONFIRMED");
  if (identityError || identities?.length !== 1) {
    throw new Error("WA100_CONFIRMED_RECIPIENT_IDENTITY_REQUIRED");
  }
  const { data: preferences, error: preferenceError } = await supabaseAdmin
    .from("whatsapp_communication_preferences")
    .select(
      "consent_status, effective_from, effective_until, quiet_hours_start, quiet_hours_end, max_messages_per_day",
    )
    .eq("identity_id", identities[0].id)
    .eq("communication_class", "TRANSACTIONAL")
    .lte("effective_from", at)
    .order("effective_from", { ascending: false })
    .limit(1);
  const preference = preferences?.[0];
  if (
    preferenceError || !preference ||
    !["OPTED_IN", "LEGITIMATE_SERVICE"].includes(preference.consent_status) ||
    (preference.effective_until && preference.effective_until <= at)
  ) {
    throw new Error("WA100_TRANSACTIONAL_CONSENT_REQUIRED");
  }
  // Quiet-hour and frequency-bound scheduling is a separate release contract.
  // Never silently ignore configured recipient limits.
  if (
    preference.quiet_hours_start != null ||
    preference.quiet_hours_end != null ||
    preference.max_messages_per_day != null
  ) {
    throw new Error("WA100_RECIPIENT_SCHEDULE_AUTHORITY_REQUIRED");
  }
  return digits;
}

async function handleSOCreated(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(supabaseAdmin, orderId);
  const recipientPhone = await resolveAuthorizedOrderRecipient(
    supabaseAdmin,
    order.company_id,
  );

  const message = `Hi! Your order SO-${order.order_number} has been created.
Amount: ₹${order.sales_order_value}
Advance due: ₹${order.advance_required}

Reply CONFIRM to proceed with payment.`;

  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "so_created",
    "so_confirmation",
    recipientPhone,
    message,
    order.company_id ?? undefined,
  );
}

async function handlePaymentVerified(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(supabaseAdmin, orderId);
  const recipientPhone = await resolveAuthorizedOrderRecipient(
    supabaseAdmin,
    order.company_id,
  );

  const message = `✓ Payment verified for SO-${order.order_number}
Your order is now in production. We'll update you soon!`;
  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "payment_verified",
    "payment_confirmed",
    recipientPhone,
    message,
    order.company_id ?? undefined,
  );
}

async function handleProductionStarted(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(supabaseAdmin, orderId);
  const recipientPhone = await resolveAuthorizedOrderRecipient(
    supabaseAdmin,
    order.company_id,
  );

  const message = `🏭 Production started for SO-${order.order_number}
Expected completion in 2-3 days. We'll keep you updated!`;
  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "production_started",
    "production_alert",
    recipientPhone,
    message,
    order.company_id ?? undefined,
  );
}

async function handleOrderDispatched(
  supabaseAdmin: SupabaseClient,
  orderId: string,
): Promise<void> {
  const order = await loadOrder(supabaseAdmin, orderId);
  const recipientPhone = await resolveAuthorizedOrderRecipient(
    supabaseAdmin,
    order.company_id,
  );

  const message = `📦 Your order SO-${order.order_number} is on the way!
Track updates on our app or reply here for support.`;
  await dispatchOrderAutomation(
    supabaseAdmin,
    orderId,
    "order_dispatched",
    "dispatch_alert",
    recipientPhone,
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

    // Explicit protected-release switch: legacy messages remain disabled
    // until business recipient, template and provider policy are certified.
    if (Deno.env.get("WA100_LEGACY_ORDER_AUTOMATION_SEND_ENABLED") !== "true") {
      return json({ error: "WA100_AUTOMATION_RELEASE_NOT_AUTHORIZED" }, 503);
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
