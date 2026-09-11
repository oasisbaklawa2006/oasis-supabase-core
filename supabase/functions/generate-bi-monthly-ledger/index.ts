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

type RunArgs = {
  company_id?: string | null;
  period_start?: string | null;
  period_end?: string | null;
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

function parseDate(value: string | null | undefined): Date | null {
  if (!value) return null;
  const parsed = new Date(value);
  return Number.isFinite(parsed.getTime()) ? parsed : null;
}

async function buildLedgerPdf(args: {
  businessName: string;
  periodStart: string;
  periodEnd: string;
  rows: { date: string; orderRef: string; status: string; amount: number }[];
  total: number;
}): Promise<Uint8Array> {
  const pdfDoc = await PDFDocument.create();
  const page = pdfDoc.addPage([595, 842]);
  const helv = await pdfDoc.embedFont(StandardFonts.Helvetica);
  const bold = await pdfDoc.embedFont(StandardFonts.HelveticaBold);
  const champagne = rgb(0.72, 0.52, 0.04);
  const ink = rgb(0.13, 0.16, 0.22);
  const mute = rgb(0.45, 0.49, 0.55);
  const line = rgb(0.85, 0.87, 0.91);

  page.drawText("OASIS BAKLAWA", { x: 40, y: 790, size: 18, font: bold, color: ink });
  page.drawText("Bi-Monthly Account Statement", { x: 40, y: 770, size: 11, font: helv, color: mute });
  page.drawText("Account Statement", { x: 400, y: 790, size: 12, font: bold, color: champagne });
  page.drawText(`Period: ${fmtDate(args.periodStart)} - ${fmtDate(args.periodEnd)}`, {
    x: 400, y: 772, size: 9, font: helv, color: mute,
  });
  page.drawLine({ start: { x: 40, y: 755 }, end: { x: 555, y: 755 }, thickness: 1, color: champagne });
  page.drawText("BILLED TO", { x: 40, y: 730, size: 8, font: bold, color: mute });
  page.drawText(args.businessName, { x: 40, y: 712, size: 13, font: bold, color: ink });
  page.drawText("We have shared this gentle account summary for your kind reconciliation. If everything aligns,", {
    x: 40, y: 685, size: 9, font: helv, color: mute,
  });
  page.drawText("no action is needed. If you spot any discrepancy, kindly reply 'Request Correction' on WhatsApp.", {
    x: 40, y: 672, size: 9, font: helv, color: mute,
  });

  let y = 640;
  page.drawRectangle({ x: 40, y: y - 4, width: 515, height: 22, color: rgb(0.96, 0.97, 0.99) });
  page.drawText("DATE", { x: 50, y: y + 4, size: 9, font: bold, color: ink });
  page.drawText("ORDER REF", { x: 145, y: y + 4, size: 9, font: bold, color: ink });
  page.drawText("STATUS", { x: 305, y: y + 4, size: 9, font: bold, color: ink });
  page.drawText("AMOUNT", { x: 480, y: y + 4, size: 9, font: bold, color: ink });
  y -= 28;

  for (const row of args.rows) {
    if (y < 80) {
      page.drawText("(continued on next page)", { x: 40, y: 60, size: 8, font: helv, color: mute });
      break;
    }
    page.drawText(fmtDate(row.date), { x: 50, y, size: 9, font: helv, color: ink });
    page.drawText(row.orderRef, { x: 145, y, size: 9, font: helv, color: ink });
    page.drawText(row.status, { x: 305, y, size: 9, font: helv, color: mute });
    page.drawText(fmtINR(row.amount), { x: 480, y, size: 9, font: bold, color: ink });
    y -= 16;
    page.drawLine({ start: { x: 40, y: y + 8 }, end: { x: 555, y: y + 8 }, thickness: 0.3, color: line });
  }

  if (args.rows.length === 0) {
    page.drawText("No orders in this period.", { x: 50, y, size: 10, font: helv, color: mute });
    y -= 20;
  }

  y -= 10;
  page.drawLine({ start: { x: 40, y: y + 6 }, end: { x: 555, y: y + 6 }, thickness: 1, color: champagne });
  page.drawText("TOTAL OUTSTANDING (FOR PERIOD)", { x: 50, y: y - 12, size: 10, font: bold, color: ink });
  page.drawText(fmtINR(args.total), { x: 460, y: y - 12, size: 12, font: bold, color: champagne });
  page.drawText("Thank you for your continued partnership with Oasis Baklawa.", {
    x: 40, y: 50, size: 9, font: helv, color: mute,
  });
  page.drawText(PORTAL_URL, { x: 40, y: 36, size: 8, font: helv, color: champagne });
  return await pdfDoc.save();
}

async function sendWhatsAppPdf(phone: string, businessName: string, pdfUrl: string) {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  if (!apiKey) return { ok: false, id: null, error: "provider_not_configured" };
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  const to = to91(phone);
  if (!/^91\d{10}$/.test(to)) return { ok: false, id: null, error: "invalid_phone" };

  const message = `Dear ${businessName},\n\nAs part of our gentle bi-monthly reconciliation, here is your account statement for the last 15 days.\n\nKindly review at your convenience. If everything matches, no reply is needed.\nIf something seems off, simply reply *Request Correction* and our Oasis team will review it together with you.\n\n${pdfUrl}\n\nWith warm regards,\n— Team Oasis Baklawa`;
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
        document: { link: pdfUrl, filename: "Oasis-Account-Statement.pdf", caption: message },
      }),
    });
    const payload = await response.json().catch(() => ({}));
    if (response.ok) return { ok: true, id: payload?.messages?.[0]?.id || payload?.id || "sent", error: null };
  } catch (error) {
    console.warn("[generate-bi-monthly-ledger] document delivery failed", error instanceof Error ? error.name : "unknown");
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
    console.warn("[generate-bi-monthly-ledger] text delivery failed", error instanceof Error ? error.name : "unknown");
    return { ok: false, id: null, error: "provider_unavailable" };
  }
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

  const today = new Date();
  const requestedEnd = parseDate(body.period_end);
  const requestedStart = parseDate(body.period_start);
  if ((body.period_end && !requestedEnd) || (body.period_start && !requestedStart)) {
    return jsonResponse({ ok: false, error: "invalid_period" }, 400);
  }
  const periodEnd = requestedEnd ?? today;
  const periodStart = requestedStart ?? new Date(periodEnd.getTime() - 14 * 24 * 3600 * 1000);
  if (periodStart.getTime() > periodEnd.getTime()) return jsonResponse({ ok: false, error: "invalid_period" }, 400);

  const periodStartIso = periodStart.toISOString().slice(0, 10);
  const periodEndIso = periodEnd.toISOString().slice(0, 10);

  try {
    let companies: { id: string; business_name: string; phone: string | null }[] = [];
    if (body.company_id) {
      const { data, error } = await admin.from("companies").select("id, business_name, phone, payment_terms").eq("id", body.company_id).maybeSingle();
      if (error) throw error;
      if (data) companies = [data as typeof companies[number]];
    } else {
      const { data, error } = await admin.from("companies").select("id, business_name, phone, payment_terms").eq("payment_terms", "credit");
      if (error) throw error;
      companies = (data || []) as typeof companies;
    }

    const results: Record<string, unknown>[] = [];
    let generated = 0;
    for (const company of companies) {
      const { data: existing, error: existingError } = await admin
        .from("bi_monthly_ledgers")
        .select("id, pdf_url, whatsapp_message_id")
        .eq("company_id", company.id)
        .eq("period_start", periodStartIso)
        .eq("period_end", periodEndIso)
        .eq("status", "sent")
        .maybeSingle();
      if (existingError) throw existingError;
      if (existing) {
        results.push({ company_id: company.id, ok: true, duplicate_suppressed: true, ledger_id: existing.id });
        continue;
      }

      const { data: orders, error: ordersError } = await admin
        .from("orders")
        .select("id, status, sales_order_value, created_at")
        .eq("company_id", company.id)
        .gte("created_at", `${periodStartIso}T00:00:00`)
        .lte("created_at", `${periodEndIso}T23:59:59`)
        .order("created_at", { ascending: true });
      if (ordersError) throw ordersError;

      const rows = (orders || []).map((order: any) => ({
        date: order.created_at,
        orderRef: `SO-${String(order.id).slice(0, 8).toUpperCase()}`,
        status: String(order.status || "").replace(/_/g, " "),
        amount: Number(order.sales_order_value || 0),
      }));
      const total = rows.reduce((sum, row) => sum + row.amount, 0);
      const pdfBytes = await buildLedgerPdf({ businessName: company.business_name, periodStart: periodStartIso, periodEnd: periodEndIso, rows, total });
      const path = `ledgers/${company.id}/${periodStartIso}_${periodEndIso}.pdf`;
      const { error: uploadError } = await admin.storage.from("final-invoices").upload(path, pdfBytes, { contentType: "application/pdf", upsert: true });
      if (uploadError) {
        results.push({ company_id: company.id, ok: false, error: "pdf_upload_failed" });
        continue;
      }
      const { data: publicData } = admin.storage.from("final-invoices").getPublicUrl(path);
      const pdfUrl = publicData.publicUrl;

      const { data: ledger, error: ledgerError } = await admin.from("bi_monthly_ledgers").insert({
        company_id: company.id,
        period_start: periodStartIso,
        period_end: periodEndIso,
        total_amount: total,
        order_count: rows.length,
        pdf_url: pdfUrl,
        status: "sent",
        generated_by: authority.userId,
        sent_at: null,
      }).select("id").single();
      if (ledgerError) {
        if ((ledgerError as any).code === "23505") {
          results.push({ company_id: company.id, ok: true, duplicate_suppressed: true });
          continue;
        }
        throw ledgerError;
      }

      let deliveryId: string | null = null;
      if (company.phone) {
        const delivery = await sendWhatsAppPdf(company.phone, company.business_name, pdfUrl);
        if (delivery.ok) {
          deliveryId = delivery.id;
          await admin.from("bi_monthly_ledgers").update({ whatsapp_message_id: deliveryId, sent_at: new Date().toISOString() }).eq("id", ledger.id);
        }
      }
      generated += 1;
      results.push({ company_id: company.id, ok: true, ledger_id: ledger.id, order_count: rows.length, total, wa_sent: Boolean(deliveryId) });
    }

    return jsonResponse({ ok: true, generated, period_start: periodStartIso, period_end: periodEndIso, results });
  } catch (error) {
    console.error("[generate-bi-monthly-ledger] failure", error instanceof Error ? error.message : "unknown");
    return jsonResponse({ ok: false, error: "internal_error" }, 500);
  }
});
