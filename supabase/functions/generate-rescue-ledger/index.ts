import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { PDFDocument, StandardFonts, rgb } from "https://esm.sh/pdf-lib@1.17.1";
import {
  corsHeaders,
  createAdminClient,
  jsonResponse,
  requireFinancialLedgerAuthority,
} from "../_shared/financialLedgerAuthority.ts";

const PORTAL_URL = "https://b2b.oasisbaklawa.com";
const PROVIDER_TIMEOUT_MS = 10_000;
const LEDGER_KIND = "rescue_reminder";

type RunArgs = {
  company_id?: string | null;
  dry_run?: boolean;
};

type LedgerRow = {
  id: string;
  pdf_url: string | null;
  whatsapp_message_id: string | null;
  delivery_status: string;
  delivery_attempt_count: number;
};

function to91(raw: string): string {
  const digits = (raw || "").replace(/\D/g, "");
  if (digits.length === 10) return `91${digits}`;
  if (digits.length === 12 && digits.startsWith("91")) return digits;
  return digits;
}

function fmtINR(value: number): string {
  return "Rs. " + (value || 0).toLocaleString("en-IN", { maximumFractionDigits: 2 });
}

function fmtDate(value: string | null): string {
  if (!value) return "-";
  return new Date(value).toLocaleDateString("en-IN", {
    day: "2-digit",
    month: "short",
    year: "numeric",
  });
}

async function buildRescuePdf(args: {
  businessName: string;
  rescueBalance: number;
  rescuePaidOn: string | null;
  accruedRows: { date: string; orderRef: string; amount: number }[];
  accruedTotal: number;
  totalDue: number;
  settlementDeadline: string | null;
}): Promise<Uint8Array> {
  const pdf = await PDFDocument.create();
  const page = pdf.addPage([595, 842]);
  const helv = await pdf.embedFont(StandardFonts.Helvetica);
  const bold = await pdf.embedFont(StandardFonts.HelveticaBold);
  const champagne = rgb(0.72, 0.52, 0.04);
  const ink = rgb(0.13, 0.16, 0.22);
  const mute = rgb(0.45, 0.49, 0.55);
  const soft = rgb(0.92, 0.85, 0.62);

  page.drawText("OASIS BAKLAWA", { x: 40, y: 790, size: 18, font: bold, color: ink });
  page.drawText("Continuity Period Statement", { x: 40, y: 770, size: 11, font: helv, color: mute });
  page.drawText("Settlement Reminder", { x: 400, y: 790, size: 12, font: bold, color: champagne });
  if (args.settlementDeadline) {
    page.drawText(`Due by: ${fmtDate(args.settlementDeadline)}`, { x: 400, y: 772, size: 9, font: helv, color: mute });
  }
  page.drawLine({ start: { x: 40, y: 755 }, end: { x: 555, y: 755 }, thickness: 1, color: champagne });
  page.drawText("BILLED TO", { x: 40, y: 730, size: 8, font: bold, color: mute });
  page.drawText(args.businessName, { x: 40, y: 712, size: 13, font: bold, color: ink });
  page.drawText("Dear Partner,", { x: 40, y: 685, size: 10, font: helv, color: ink });
  page.drawText("Thank you for the rescue payment that restored your continuity. Below is a gentle summary", {
    x: 40, y: 668, size: 9, font: helv, color: mute,
  });
  page.drawText("of the remaining rescue balance and all purchases made during the continuity window.", {
    x: 40, y: 654, size: 9, font: helv, color: mute,
  });
  page.drawRectangle({ x: 40, y: 615, width: 515, height: 30, color: soft });
  page.drawText("REMAINING RESCUE BALANCE", { x: 50, y: 628, size: 9, font: bold, color: ink });
  page.drawText(fmtINR(args.rescueBalance), { x: 460, y: 624, size: 13, font: bold, color: ink });
  if (args.rescuePaidOn) page.drawText(`since ${fmtDate(args.rescuePaidOn)}`, { x: 50, y: 618, size: 7, font: helv, color: mute });

  let y = 580;
  page.drawText("ACCRUED PURCHASES (CONTINUITY PERIOD)", { x: 40, y, size: 9, font: bold, color: ink });
  y -= 18;
  page.drawRectangle({ x: 40, y: y - 4, width: 515, height: 22, color: rgb(0.96, 0.97, 0.99) });
  page.drawText("DATE", { x: 50, y: y + 4, size: 9, font: bold, color: ink });
  page.drawText("ORDER REF", { x: 145, y: y + 4, size: 9, font: bold, color: ink });
  page.drawText("AMOUNT", { x: 480, y: y + 4, size: 9, font: bold, color: ink });
  y -= 24;

  for (const row of args.accruedRows) {
    if (y < 140) {
      page.drawText("(continued)", { x: 40, y: 130, size: 8, font: helv, color: mute });
      break;
    }
    page.drawText(fmtDate(row.date), { x: 50, y, size: 9, font: helv, color: ink });
    page.drawText(row.orderRef, { x: 145, y, size: 9, font: helv, color: ink });
    page.drawText(fmtINR(row.amount), { x: 480, y, size: 9, font: bold, color: ink });
    y -= 14;
  }
  if (args.accruedRows.length === 0) {
    page.drawText("No new orders during continuity period.", { x: 50, y, size: 9, font: helv, color: mute });
    y -= 16;
  }
  y = Math.min(y, 130);
  page.drawLine({ start: { x: 40, y: y + 6 }, end: { x: 555, y: y + 6 }, thickness: 0.5, color: mute });
  page.drawText("Accrued total", { x: 50, y: y - 8, size: 9, font: helv, color: mute });
  page.drawText(fmtINR(args.accruedTotal), { x: 480, y: y - 8, size: 9, font: helv, color: ink });
  page.drawLine({ start: { x: 40, y: y - 18 }, end: { x: 555, y: y - 18 }, thickness: 1, color: champagne });
  page.drawText("TOTAL SETTLEMENT DUE BY MONTH-END", { x: 50, y: y - 32, size: 10, font: bold, color: ink });
  page.drawText(fmtINR(args.totalDue), { x: 460, y: y - 32, size: 13, font: bold, color: champagne });
  page.drawText("With warm regards — Team Oasis Baklawa", { x: 40, y: 50, size: 9, font: helv, color: mute });
  page.drawText(PORTAL_URL, { x: 40, y: 36, size: 8, font: helv, color: champagne });
  return await pdf.save();
}

async function sendSoftWhatsApp(
  phone: string,
  businessName: string,
  totalDue: number,
  deadline: string | null,
  pdfUrl: string,
) {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  if (!apiKey) return { ok: false, id: null, error: "provider_not_configured" };
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  const to = to91(phone);
  if (!/^91\d{10}$/.test(to)) return { ok: false, id: null, error: "invalid_phone" };
  const deadlineStr = deadline ? fmtDate(deadline) : "month-end";
  const message = `Dear ${businessName},\n\nA gentle reminder of your continuity-period statement.\n\nTotal settlement due by *${deadlineStr}*: *${fmtINR(totalDue)}*\n\nThis includes the remaining rescue balance and all new purchases during the continuity window.\n\nFull ledger: ${pdfUrl}\n\nIf anything looks off, kindly reply *Request Correction* and our team will gladly review with you.\n\nWith warm regards,\n— Team Oasis Baklawa`;
  const providerHeaders = {
    "Content-Type": "application/json",
    apikey: apiKey,
    ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
  };

  try {
    const response = await fetch("https://crm.click2api.in/api/v1/messages", {
      method: "POST",
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      headers: providerHeaders,
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to,
        type: "document",
        document: { link: pdfUrl, filename: "Oasis-Continuity-Statement.pdf", caption: message },
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (response.ok) return { ok: true, id: payload?.messages?.[0]?.id || payload?.id || "sent", error: null };
  } catch (error) {
    console.warn("[generate-rescue-ledger] document delivery failed", error instanceof Error ? error.name : "unknown");
  }

  try {
    const response = await fetch("https://crm.click2api.in/api/v1/messages", {
      method: "POST",
      signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS),
      headers: providerHeaders,
      body: JSON.stringify({ messaging_product: "whatsapp", to, type: "text", text: { body: message } }),
    });
    const payload = await response.json().catch(() => ({}));
    return response.ok
      ? { ok: true, id: payload?.messages?.[0]?.id || payload?.id || "sent", error: null }
      : { ok: false, id: null, error: "provider_rejected" };
  } catch (error) {
    console.warn("[generate-rescue-ledger] text delivery failed", error instanceof Error ? error.name : "unknown");
    return { ok: false, id: null, error: "provider_unavailable" };
  }
}

async function deliverLedger(
  admin: ReturnType<typeof createAdminClient>,
  ledger: LedgerRow,
  phone: string | null,
  businessName: string,
  totalDue: number,
  deadline: string | null,
): Promise<Record<string, unknown>> {
  if (!phone) {
    await admin.from("bi_monthly_ledgers").update({
      delivery_status: "skipped",
      last_delivery_error: "phone_unavailable",
    }).eq("id", ledger.id);
    return { ok: true, delivery_status: "skipped", reason: "phone_unavailable" };
  }
  if (!ledger.pdf_url) {
    await admin.from("bi_monthly_ledgers").update({
      delivery_status: "failed",
      last_delivery_error: "pdf_url_unavailable",
    }).eq("id", ledger.id);
    return { ok: false, delivery_status: "failed", error: "pdf_url_unavailable" };
  }

  const nextAttempt = Number(ledger.delivery_attempt_count || 0) + 1;
  const delivery = await sendSoftWhatsApp(phone, businessName, totalDue, deadline, ledger.pdf_url);
  if (delivery.ok) {
    const sentAt = new Date().toISOString();
    await admin.from("bi_monthly_ledgers").update({
      delivery_status: "sent",
      delivery_attempt_count: nextAttempt,
      last_delivery_error: null,
      whatsapp_message_id: delivery.id,
      sent_at: sentAt,
    }).eq("id", ledger.id);
    return { ok: true, delivery_status: "sent", whatsapp_message_id: delivery.id };
  }

  await admin.from("bi_monthly_ledgers").update({
    delivery_status: "failed",
    delivery_attempt_count: nextAttempt,
    last_delivery_error: delivery.error || "provider_failed",
  }).eq("id", ledger.id);
  return { ok: false, delivery_status: "failed", error: delivery.error || "provider_failed" };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders() });
  if (req.method !== "POST") return jsonResponse({ ok: false, error: "method_not_allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const publicKey = Deno.env.get("SUPABASE_ANON_KEY") || Deno.env.get("SUPABASE_PUBLISHABLE_KEY") || "";
  if (!supabaseUrl || !serviceRoleKey) return jsonResponse({ ok: false, error: "service_unavailable" }, 503);

  const authority = await requireFinancialLedgerAuthority(req, supabaseUrl, serviceRoleKey, publicKey);
  if (!authority.ok) return jsonResponse({ ok: false, error: authority.error }, authority.status);
  const admin = createAdminClient(supabaseUrl, serviceRoleKey);

  let body: RunArgs = {};
  try {
    body = (await req.json()) as RunArgs;
  } catch {
    body = {};
  }

  try {
    const now = new Date();
    const ist = new Date(now.getTime() + 5.5 * 3600 * 1000);
    const startOfMonth = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), 1)).toISOString();

    let query = admin
      .from("companies")
      .select("id, business_name, phone, total_outstanding, rescue_payment_date, settlement_deadline")
      .eq("payment_terms", "credit");
    query = body.company_id ? query.eq("id", body.company_id) : query.gt("total_outstanding", 0);
    const { data: companies, error: companyError } = await query;
    if (companyError) throw companyError;

    const targets = (companies || []).filter((company: any) =>
      Number(company.total_outstanding || 0) > 0 ||
      (company.rescue_payment_date && company.rescue_payment_date >= startOfMonth)
    );

    if (body.dry_run === true) {
      return jsonResponse({
        ok: true,
        dry_run: true,
        authorized_as: authority.kind,
        target_companies: targets.length,
      });
    }

    const results: Record<string, unknown>[] = [];
    let generated = 0;

    for (const company of targets) {
      const anchor = company.rescue_payment_date || startOfMonth;
      const periodStart = String(anchor).slice(0, 10);
      const periodEnd = new Date().toISOString().slice(0, 10);

      const { data: existing, error: existingError } = await admin
        .from("bi_monthly_ledgers")
        .select("id, pdf_url, whatsapp_message_id, delivery_status, delivery_attempt_count")
        .eq("company_id", company.id)
        .eq("period_start", periodStart)
        .eq("period_end", periodEnd)
        .eq("ledger_kind", LEDGER_KIND)
        .maybeSingle();
      if (existingError) throw existingError;
      if (existing) {
        const ledger = existing as LedgerRow;
        if (["sent", "skipped"].includes(ledger.delivery_status)) {
          results.push({ company_id: company.id, ok: true, duplicate_suppressed: true, ledger_id: ledger.id, delivery_status: ledger.delivery_status });
          continue;
        }
        const retry = await deliverLedger(
          admin,
          ledger,
          company.phone,
          company.business_name,
          Number(company.total_outstanding || 0),
          company.settlement_deadline,
        );
        results.push({ company_id: company.id, ledger_id: ledger.id, retried: true, ...retry });
        continue;
      }

      const { data: orders, error: ordersError } = await admin
        .from("orders")
        .select("id, sales_order_value, created_at")
        .eq("company_id", company.id)
        .gte("created_at", anchor)
        .not("status", "in", "(draft,cart,cancelled)")
        .order("created_at", { ascending: true });
      if (ordersError) throw ordersError;

      const accruedRows = (orders || []).map((order: any) => ({
        date: order.created_at,
        orderRef: `SO-${String(order.id).slice(0, 8).toUpperCase()}`,
        amount: Number(order.sales_order_value || 0),
      }));
      const accruedTotal = accruedRows.reduce((sum, row) => sum + row.amount, 0);
      const totalDue = Number(company.total_outstanding || 0);
      const rescueBalance = Math.max(0, totalDue - accruedTotal);
      const pdfBytes = await buildRescuePdf({
        businessName: company.business_name,
        rescueBalance,
        rescuePaidOn: company.rescue_payment_date,
        accruedRows,
        accruedTotal,
        totalDue,
        settlementDeadline: company.settlement_deadline,
      });
      const path = `rescue/${company.id}/${periodStart}_${periodEnd}.pdf`;
      const { error: uploadError } = await admin.storage.from("final-invoices").upload(path, pdfBytes, { contentType: "application/pdf", upsert: true });
      if (uploadError) {
        results.push({ company_id: company.id, ok: false, error: "pdf_upload_failed" });
        continue;
      }
      const { data: publicData } = admin.storage.from("final-invoices").getPublicUrl(path);
      const pdfUrl = publicData.publicUrl;

      const { data: ledger, error: ledgerError } = await admin.from("bi_monthly_ledgers").insert({
        company_id: company.id,
        period_start: periodStart,
        period_end: periodEnd,
        total_amount: totalDue,
        order_count: accruedRows.length,
        pdf_url: pdfUrl,
        status: "rescue_reminder",
        ledger_kind: LEDGER_KIND,
        delivery_status: "pending",
        delivery_attempt_count: 0,
        generated_by: authority.userId,
        sent_at: null,
      }).select("id, pdf_url, whatsapp_message_id, delivery_status, delivery_attempt_count").single();
      if (ledgerError) {
        if ((ledgerError as any).code === "23505") {
          results.push({ company_id: company.id, ok: true, duplicate_suppressed: true });
          continue;
        }
        throw ledgerError;
      }

      generated += 1;
      const delivery = await deliverLedger(
        admin,
        ledger as LedgerRow,
        company.phone,
        company.business_name,
        totalDue,
        company.settlement_deadline,
      );
      results.push({ company_id: company.id, ledger_id: ledger.id, rescue_balance: rescueBalance, accrued: accruedTotal, total_due: totalDue, ...delivery });
    }

    return jsonResponse({ ok: true, generated, results });
  } catch (error) {
    console.error("[generate-rescue-ledger] failure", error instanceof Error ? error.message : "unknown");
    return jsonResponse({ ok: false, error: "internal_error" }, 500);
  }
});
