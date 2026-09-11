import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.0";
import {
  approvalChannels,
  approvalIdempotencyKey,
  buildApprovalNotification,
  isAlreadySent,
  normalizeEmail,
  normalizePhone,
  nextApprovalAttempt,
  safeProviderMessage,
  type ApprovalApplication,
  type NotificationChannel,
} from "../_shared/notifyEventAuthority.ts";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type, x-supabase-client-platform, x-supabase-client-platform-version, x-supabase-client-runtime, x-supabase-client-runtime-version",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const PORTAL_URL = Deno.env.get("B2B_PORTAL_URL") || "https://b2b.oasisbaklawa.com";
const CLICK2API_SEND_ENDPOINT = "https://crm.click2api.in/api/v1/messages";
const MSG91_WHATSAPP_ENDPOINT =
  "https://control.msg91.com/api/v5/whatsapp/whatsapp-outbound-message/bulk/";

type Audience = "buyer" | "sales_exec" | "admin";
type NotifyPayload = {
  event?: unknown;
  subject?: unknown;
  message?: unknown;
  audiences?: unknown;
  applicationId?: unknown;
  orderId?: unknown;
  companyId?: unknown;
  email?: unknown;
  phone?: unknown;
};

type Recipient = {
  label: string;
  email: string | null;
  phone: string | null;
};

type ProviderResult = {
  ok: boolean;
  provider: string;
  messageId?: string | null;
  status?: number;
  error?: string;
};

const json = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });

function asString(value: unknown): string | null {
  return typeof value === "string" && value.trim() ? value.trim() : null;
}

function audiencesFrom(value: unknown): Audience[] {
  if (!Array.isArray(value)) return ["buyer"];
  return value.filter((item): item is Audience =>
    item === "buyer" || item === "sales_exec" || item === "admin"
  );
}

async function requireInternalStaff(
  req: Request,
  supabaseUrl: string,
  serviceRoleKey: string,
  publicKey: string,
) {
  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    return { ok: false as const, status: 401, error: "Unauthorized", userId: null };
  }
  const token = authorization.slice(7).trim();
  if (!token) return { ok: false as const, status: 401, error: "Unauthorized", userId: null };
  if (token === serviceRoleKey) {
    return { ok: true as const, userId: null, kind: "service_role" as const };
  }

  const authClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: userData, error: userError } = await authClient.auth.getUser(token);
  if (userError || !userData.user?.id) {
    return { ok: false as const, status: 401, error: "Unauthorized", userId: null };
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data: isStaff, error: staffError } = await admin.rpc("is_internal_staff", {
    _user_id: userData.user.id,
  });
  if (staffError) {
    console.error("[notify-event] staff lookup failed", staffError.message);
    return { ok: false as const, status: 500, error: "Unable to verify staff access", userId: null };
  }
  if (isStaff !== true) {
    return { ok: false as const, status: 403, error: "Forbidden", userId: userData.user.id };
  }
  return { ok: true as const, userId: userData.user.id, kind: "staff" as const };
}

async function sendEmail(to: string, subject: string, message: string): Promise<ProviderResult> {
  const resendKey = Deno.env.get("RESEND_API_KEY");
  if (!resendKey) return { ok: false, provider: "resend", error: "provider_not_configured" };

  const escaped = message.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
  const html = `<div style="font-family:Arial,sans-serif;max-width:600px;margin:0 auto;padding:24px;color:#1a1a1a">
    <div style="border-bottom:2px solid #c9a961;padding-bottom:12px;margin-bottom:20px">
      <h2 style="margin:0;font-weight:600">Oasis Baklawa B2B</h2>
    </div>
    <div style="white-space:pre-wrap;line-height:1.6;font-size:14px">${escaped}</div>
    <div style="margin-top:28px;padding-top:16px;border-top:1px solid #eee;font-size:12px;color:#888">
      <a href="${PORTAL_URL}" style="color:#c9a961;text-decoration:none;font-weight:600">Open B2B Portal →</a>
    </div>
  </div>`;

  try {
    const response = await fetch("https://api.resend.com/emails", {
      method: "POST",
      headers: { "Content-Type": "application/json", Authorization: `Bearer ${resendKey}` },
      body: JSON.stringify({
        from: "Oasis Baklawa <team@oasisbaklawa.com>",
        to,
        subject,
        html,
      }),
    });
    const body = await response.json().catch(() => ({}));
    return response.ok
      ? { ok: true, provider: "resend", messageId: body?.id ?? null, status: response.status }
      : { ok: false, provider: "resend", status: response.status, error: safeProviderMessage(body?.message) };
  } catch (error) {
    return { ok: false, provider: "resend", error: safeProviderMessage(error) };
  }
}

async function sendWhatsAppViaClick2API(to: string, message: string): Promise<ProviderResult> {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  if (!apiKey) return { ok: false, provider: "click2api", error: "provider_not_configured" };
  try {
    const response = await fetch(CLICK2API_SEND_ENDPOINT, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        apikey: apiKey,
        ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to,
        type: "text",
        text: { body: message },
      }),
    });
    const body = await response.json().catch(() => ({}));
    return response.ok
      ? { ok: true, provider: "click2api", messageId: body?.message_id ?? body?.id ?? null, status: response.status }
      : { ok: false, provider: "click2api", status: response.status, error: safeProviderMessage(body?.message) };
  } catch (error) {
    return { ok: false, provider: "click2api", error: safeProviderMessage(error) };
  }
}

async function sendWhatsAppViaMSG91(to: string, message: string): Promise<ProviderResult> {
  const authKey = Deno.env.get("MSG91_AUTH_KEY");
  const senderId = Deno.env.get("MSG91_SENDER_ID") || "OASBKL";
  if (!authKey) return { ok: false, provider: "msg91", error: "provider_not_configured" };
  try {
    const response = await fetch(MSG91_WHATSAPP_ENDPOINT, {
      method: "POST",
      headers: { "Content-Type": "application/json", authkey: authKey },
      body: JSON.stringify({
        integrated_number: senderId,
        content_type: "text",
        payload: { to, type: "text", text: { body: message } },
      }),
    });
    const body = await response.json().catch(() => ({}));
    return response.ok
      ? { ok: true, provider: "msg91", messageId: body?.request_id ?? body?.id ?? null, status: response.status }
      : { ok: false, provider: "msg91", status: response.status, error: safeProviderMessage(body?.message) };
  } catch (error) {
    return { ok: false, provider: "msg91", error: safeProviderMessage(error) };
  }
}

async function sendWhatsApp(to: string, subject: string, message: string): Promise<ProviderResult> {
  const body = `*${subject}*\n\n${message}\n\n${PORTAL_URL}`;
  const click = await sendWhatsAppViaClick2API(to, body);
  if (click.ok) return click;
  const msg91 = await sendWhatsAppViaMSG91(to, body);
  if (msg91.ok) return msg91;
  return {
    ok: false,
    provider: `${click.provider}+${msg91.provider}`,
    error: `${click.error ?? "failed"}; ${msg91.error ?? "failed"}`.slice(0, 500),
    status: msg91.status ?? click.status,
  };
}

async function resolveGenericRecipients(
  admin: ReturnType<typeof createClient>,
  payload: NotifyPayload,
): Promise<{ recipients: Recipient[]; companyId: string | null }> {
  const recipients: Recipient[] = [];
  const directEmail = normalizeEmail(asString(payload.email));
  const directPhone = normalizePhone(asString(payload.phone));
  if (directEmail || directPhone) {
    recipients.push({ label: "direct", email: directEmail, phone: directPhone });
  }

  let companyId = asString(payload.companyId);
  const orderId = asString(payload.orderId);
  if (orderId && !companyId) {
    const { data: order } = await admin.from("orders").select("company_id").eq("id", orderId).maybeSingle();
    companyId = order?.company_id ?? null;
  }

  const audiences = audiencesFrom(payload.audiences);
  if (companyId) {
    const { data: company } = await admin
      .from("companies")
      .select("phone, account_manager_id")
      .eq("id", companyId)
      .maybeSingle();

    if (audiences.includes("buyer") && company) {
      const { data: app } = await admin
        .from("b2b_applications")
        .select("contact_email, mobile_number, contact_phone")
        .eq("resolved_company_id", companyId)
        .order("created_at", { ascending: false })
        .limit(1)
        .maybeSingle();
      recipients.push({
        label: "buyer",
        email: normalizeEmail(app?.contact_email),
        phone: normalizePhone(company.phone ?? app?.mobile_number ?? app?.contact_phone),
      });
    }

    if (audiences.includes("sales_exec") && company?.account_manager_id) {
      const { data: executive } = await admin
        .from("users")
        .select("email, phone")
        .eq("id", company.account_manager_id)
        .maybeSingle();
      if (executive) {
        recipients.push({
          label: "sales_exec",
          email: normalizeEmail(executive.email),
          phone: normalizePhone(executive.phone),
        });
      }
    }
  }

  if (audiences.includes("admin")) {
    const { data: admins } = await admin
      .from("users")
      .select("email, phone")
      .in("role", ["ADMIN", "SUPER_ADMIN"])
      .eq("is_active", true)
      .limit(5);
    for (const row of admins ?? []) {
      recipients.push({ label: "admin", email: normalizeEmail(row.email), phone: normalizePhone(row.phone) });
    }
  }

  return { recipients, companyId };
}

async function getOrCreateApprovalOutbox(
  admin: ReturnType<typeof createClient>,
  applicationId: string,
  channel: NotificationChannel,
  recipient: string,
  message: string,
) {
  const sourceApplication = "b2b_onboarding";
  const key = approvalIdempotencyKey(applicationId, channel);
  const { data: existing } = await admin
    .from("notification_outbox")
    .select("id,status,recipient_email,recipient_phone,message_body,attempt_count,max_attempts")
    .eq("source_application", sourceApplication)
    .eq("idempotency_key", key)
    .maybeSingle();

  const expectedEmail = channel === "email" ? recipient : null;
  const expectedPhone = channel === "whatsapp" ? recipient : null;
  if (existing) {
    if (
      existing.message_body !== message ||
      existing.recipient_email !== expectedEmail ||
      existing.recipient_phone !== expectedPhone
    ) {
      throw new Error("approval_notification_idempotency_conflict");
    }
    return existing;
  }

  const row = {
    source_application: sourceApplication,
    event_type: "b2b_access_approved",
    channel,
    message_body: message,
    idempotency_key: key,
    recipient_email: expectedEmail,
    recipient_phone: expectedPhone,
    priority: "high",
    event_id: applicationId,
    max_attempts: 5,
    next_attempt_at: new Date().toISOString(),
    status: "pending",
    attempt_count: 0,
    updated_at: new Date().toISOString(),
  };
  const { data, error } = await admin.from("notification_outbox").insert(row).select("id,status,recipient_email,recipient_phone,message_body,attempt_count,max_attempts").single();
  if (!error && data) return data;

  // Concurrency-safe replay: another identical request may have inserted first.
  const { data: replay, error: replayError } = await admin
    .from("notification_outbox")
    .select("id,status,recipient_email,recipient_phone,message_body,attempt_count,max_attempts")
    .eq("source_application", sourceApplication)
    .eq("idempotency_key", key)
    .maybeSingle();
  if (replayError || !replay) throw error ?? replayError ?? new Error("outbox_insert_failed");
  if (
    replay.message_body !== message ||
    replay.recipient_email !== expectedEmail ||
    replay.recipient_phone !== expectedPhone
  ) {
    throw new Error("approval_notification_idempotency_conflict");
  }
  return replay;
}

async function dispatchApproval(
  admin: ReturnType<typeof createClient>,
  applicationId: string,
  actorId: string | null,
) {
  const { data, error } = await admin
    .from("b2b_applications")
    .select("id,status,business_name,contact_email,mobile_number,contact_phone,assigned_price_tier")
    .eq("id", applicationId)
    .maybeSingle();
  if (error) {
    console.error("[notify-event] approval application lookup failed", error.message);
    return { status: 503, body: { error: "Approval application lookup unavailable" } };
  }
  if (!data) return { status: 404, body: { error: "Application not found" } };

  let notification: ReturnType<typeof buildApprovalNotification>;
  try {
    notification = buildApprovalNotification(data as ApprovalApplication);
  } catch (error) {
    if (error instanceof Error && error.message === "application_not_approved") {
      return { status: 409, body: { error: "application_not_approved" } };
    }
    throw error;
  }
  const channels = approvalChannels(notification);
  if (channels.length === 0) {
    return { status: 422, body: { error: "Approved application has no usable notification recipient" } };
  }

  const results: Array<Record<string, unknown>> = [];
  for (const channel of channels) {
    const recipient = channel === "email" ? notification.email : notification.phone;
    if (!recipient) continue;
    let outbox;
    try {
      outbox = await getOrCreateApprovalOutbox(
        admin,
        applicationId,
        channel,
        recipient,
        notification.message,
      );
    } catch (error) {
      if (error instanceof Error && error.message === "approval_notification_idempotency_conflict") {
        return { status: 409, body: { error: "approval_notification_idempotency_conflict" } };
      }
      throw error;
    }
    if (isAlreadySent(outbox.status)) {
      results.push({ channel, ok: true, skipped: true, outboxId: outbox.id });
      continue;
    }

    const retry = nextApprovalAttempt(outbox.attempt_count, outbox.max_attempts);
    if (!retry.allowed) {
      results.push({ channel, ok: false, skipped: true, outboxId: outbox.id, error: "max_attempts_exhausted" });
      continue;
    }
    const attemptCount = retry.nextAttemptCount;

    const provider = channel === "email"
      ? await sendEmail(recipient, notification.subject, notification.message)
      : await sendWhatsApp(recipient, notification.subject, notification.message);

    const now = new Date().toISOString();
    const { error: updateError } = await admin
      .from("notification_outbox")
      .update(provider.ok
        ? {
            status: "sent",
            sent_at: now,
            provider_message_id: provider.messageId ?? null,
            last_attempt_at: now,
            attempt_count: attemptCount,
            error_log: null,
            updated_at: now,
          }
        : {
            status: "failed",
            last_attempt_at: now,
            attempt_count: attemptCount,
            error_log: safeProviderMessage(provider.error),
            updated_at: now,
          })
      .eq("id", outbox.id);

    if (updateError) console.error("[notify-event] outbox update failed", updateError.message);
    results.push({
      channel,
      ok: provider.ok,
      provider: provider.provider,
      status: provider.status ?? null,
      outboxId: outbox.id,
      error: provider.ok ? null : "delivery_failed",
    });
  }

  const sent = results.filter((result) => result.ok === true).length;
  const failed = results.length - sent;
  await admin.from("audit_logs").insert({
    action_type: "B2B_ACCESS_APPROVAL_NOTIFICATION",
    module_name: "b2b_onboarding",
    entity_name: "b2b_applications",
    entity_id: applicationId,
    actor_id: actorId,
    risk_level: failed > 0 ? "medium" : "low",
    reason: failed > 0 ? "Approval notification partially/fully failed" : "Approval notification dispatched",
    new_value: { channels: results.map((result) => ({ channel: result.channel, ok: result.ok, skipped: result.skipped ?? false })) },
  });

  return {
    status: 200,
    body: {
      success: sent > 0,
      partial: sent > 0 && failed > 0,
      sent,
      failed,
      results,
    },
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });
  if (req.method !== "POST") return json({ error: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") ?? Deno.env.get("SUPABASE_PUBLISHABLE_KEY");
  if (!supabaseUrl || !serviceRoleKey || !publicKey) {
    return json({ error: "Authentication is not configured" }, 500);
  }

  const authorization = await requireInternalStaff(req, supabaseUrl, serviceRoleKey, publicKey);
  if (!authorization.ok) return json({ error: authorization.error }, authorization.status);

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });

  try {
    let payload: NotifyPayload;
    try {
      payload = (await req.json()) as NotifyPayload;
    } catch {
      return json({ error: "Invalid JSON body" }, 400);
    }
    const event = asString(payload.event);
    if (!event) return json({ error: "event is required" }, 400);

    if (event === "approval_granted") {
      const applicationId = asString(payload.applicationId);
      if (!applicationId) return json({ error: "applicationId is required for approval notification" }, 400);
      const carriesCallerAuthority = !!(
        asString(payload.subject) ||
        asString(payload.message) ||
        asString(payload.email) ||
        asString(payload.phone) ||
        asString(payload.orderId) ||
        asString(payload.companyId) ||
        (Array.isArray(payload.audiences) && payload.audiences.length > 0)
      );
      if (carriesCallerAuthority) {
        return json({ error: "approval notification fields are server-authoritative" }, 400);
      }
      const outcome = await dispatchApproval(admin, applicationId, authorization.userId);
      return json(outcome.body, outcome.status);
    }

    const subject = asString(payload.subject);
    const message = asString(payload.message);
    if (!subject || !message) return json({ error: "subject and message are required" }, 400);

    const { recipients, companyId } = await resolveGenericRecipients(admin, payload);
    const results: Array<Record<string, unknown>> = [];
    for (const recipient of recipients) {
      if (recipient.email) {
        const result = await sendEmail(recipient.email, subject, message);
        results.push({ label: recipient.label, channel: "email", ok: result.ok, provider: result.provider, status: result.status ?? null });
      }
      if (recipient.phone) {
        const result = await sendWhatsApp(recipient.phone, subject, message);
        results.push({ label: recipient.label, channel: "whatsapp", ok: result.ok, provider: result.provider, status: result.status ?? null });
      }
    }

    await admin.from("audit_logs").insert({
      action_type: "notify_event",
      module_name: "notifications",
      entity_name: event,
      entity_id: asString(payload.orderId) ?? companyId,
      actor_id: authorization.userId,
      risk_level: results.some((result) => result.ok !== true) ? "medium" : "low",
      reason: subject,
      new_value: { recipients: recipients.length, channels: results.map((result) => ({ channel: result.channel, ok: result.ok })) },
    });

    return json({ success: results.some((result) => result.ok === true), dispatched: results.length, results });
  } catch (error) {
    const message = safeProviderMessage(error);
    console.error("[notify-event] fatal", message);
    return json({ error: "Unable to dispatch notification" }, 500);
  }
});
