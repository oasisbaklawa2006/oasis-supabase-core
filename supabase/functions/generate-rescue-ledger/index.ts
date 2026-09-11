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
const LEDGER_BUCKET = "final-invoices";
const SIGNED_LEDGER_URL_TTL_SECONDS = 60 * 60;

type RunArgs = { company_id?: string | null; dry_run?: boolean };
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
  return new Date(value).toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric" });
}
function storageRef(path: string): string { return `storage:${LEDGER_BUCKET}/${path}`; }
function storagePathFromRef(value: string | null): string | null {
  if (!value) return null;
  const canonicalPrefix = `storage:${LEDGER_BUCKET}/`;
  if (value.startsWith(canonicalPrefix)) return value.slice(canonicalPrefix.length);
  const legacyMarker = `/storage/v1/object/public/${LEDGER_BUCKET}/`;
  const markerIndex = value.indexOf(legacyMarker);
  if (markerIndex === -1) return null;
  try { return decodeURIComponent(value.slice(markerIndex + legacyMarker.length).split("?")[0]); } catch { return null; }
}
async function createLedgerSignedUrl(admin: ReturnType<typeof createAdminClient>, storedRef: string | null): Promise<string | null> {
  const path = storagePathFromRef(storedRef);
  if (!path) return null;
  const { data, error } = await admin.storage.from(LEDGER_BUCKET).createSignedUrl(path, SIGNED_LEDGER_URL_TTL_SECONDS);
  if (error || !data?.signedUrl) {
    console.error("[generate-rescue-ledger] signed URL creation failed", error?.message ?? "missing_signed_url");
    return null;
  }
  return data.signedUrl;
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
  const gold = rgb(0.72, 0.52, 0.04);
  const ink = rgb(0.13, 0.16, 0.22);
  const mute = rgb(0.45, 0.49, 0.55);
  page.drawText("OASIS BAKLAWA", { x: 40, y: 790, size: 18, font: bold, color: ink });
  page.drawText("Continuity Period Statement", { x: 40, y: 770, size: 11, font: helv, color: mute });
  page.drawText(args.businessName, { x: 40, y: 720, size: 13, font: bold, color: ink });
  if (args.settlementDeadline) page.drawText(`Target: ${fmtDate(args.settlementDeadline)}`, { x: 400, y: 790, size: 9, font: helv, color: mute });
  page.drawText(`Remaining rescue balance: ${fmtINR(args.rescueBalance)}`, { x: 40, y: 680, size: 11, font: bold, color: ink });
  let y = 640;
  page.drawText("CONTINUITY-PERIOD ORDER VALUES", { x: 40, y, size: 9, font: bold, color: ink });
  y -= 22;
  for (const row of args.accruedRows) {
    if (y < 130) break;
    page.drawText(fmtDate(row.date), { x: 50, y, size: 9, font: helv, color: ink });
    page.drawText(row.orderRef, { x: 155, y, size: 9, font: helv, color: ink });
    page.drawText(fmtINR(row.amount), { x: 460, y, size: 9, font: bold, color: ink });
    y -= 16;
  }
  page.drawText(`Accrued order value: ${fmtINR(args.accruedTotal)}`, { x: 40, y: 100, size: 9, font: helv, color: mute });
  page.drawText(`CURRENT TOTAL OUTSTANDING: ${fmtINR(args.totalDue)}`, { x: 40, y: 78, size: 12, font: bold, color: gold });
  page.drawText(PORTAL_URL, { x: 40, y: 36, size: 8, font: helv, color: gold });
  return await pdf.save();
}

async function sendSoftWhatsApp(phone: string, businessName: string, totalDue: number, deadline: string | null, pdfUrl: string) {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  if (!apiKey) return { ok: false, id: null, error: "provider_not_configured" };
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  const to = to91(phone);
  if (!/^91\d{10}$/.test(to)) return { ok: false, id: null, error: "invalid_phone" };
  const deadlineStr = deadline ? fmtDate(deadline) : "month-end";
  const message = `Dear ${businessName},\n\nA gentle reminder of your continuity-period statement.\n\nCurrent outstanding: *${fmtINR(totalDue)}*\nRequested settlement target: *${deadlineStr}*\n\nSecure ledger link (expires in 1 hour): ${pdfUrl}\n\nIf anything looks off, kindly reply *Request Correction*.\n\n— Team Oasis Baklawa`;
  const headers = { "Content-Type": "application/json", apikey: apiKey, ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}) };

  try {
    const response = await fetch("https://crm.click2api.in/api/v1/messages", {
      method: "POST", signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS), headers,
      body: JSON.stringify({ messaging_product: "whatsapp", to, type: "document", document: { link: pdfUrl, filename: "Oasis-Continuity-Statement.pdf", caption: message } }),
    });
    const payload = await response.json().catch(() => ({}));
    if (response.ok) return { ok: true, id: payload?.messages?.[0]?.id || payload?.id || "sent", error: null };
    // Definite rejection only: text fallback is now safe to attempt.
  } catch (error) {
    console.warn("[generate-rescue-ledger] document delivery outcome uncertain", error instanceof Error ? error.name : "unknown");
    return { ok: false, id: null, error: error instanceof DOMException && error.name === "TimeoutError" ? "provider_timeout_uncertain" : "provider_outcome_uncertain" };
  }

  try {
    const response = await fetch("https://crm.click2api.in/api/v1/messages", {
      method: "POST", signal: AbortSignal.timeout(PROVIDER_TIMEOUT_MS), headers,
      body: JSON.stringify({ messaging_product: "whatsapp", to, type: "text", text: { body: message } }),
    });
    const payload = await response.json().catch(() => ({}));
    return response.ok
      ? { ok: true, id: payload?.messages?.[0]?.id || payload?.id || "sent", error: null }
      : { ok: false, id: null, error: "provider_rejected" };
  } catch (error) {
    console.warn("[generate-rescue-ledger] fallback delivery outcome uncertain", error instanceof Error ? error.name : "unknown");
    return { ok: false, id: null, error: "provider_outcome_uncertain" };
  }
}

async function deliverLedger(
  admin: ReturnType<typeof createAdminClient>, ledger: LedgerRow, phone: string | null,
  businessName: string, totalDue: number, deadline: string | null,
): Promise<Record<string, unknown>> {
  if (!phone) {
    await admin.from("bi_monthly_ledgers").update({ delivery_status: "skipped", delivery_lease_until: null, last_delivery_error: "phone_unavailable" }).eq("id", ledger.id);
    return { ok: true, delivery_status: "skipped", reason: "phone_unavailable" };
  }
  if (!ledger.pdf_url) {
    await admin.from("bi_monthly_ledgers").update({ delivery_status: "failed", delivery_lease_until: null, last_delivery_error: "pdf_reference_unavailable" }).eq("id", ledger.id);
    return { ok: false, delivery_status: "failed", error: "pdf_reference_unavailable" };
  }
  const { data: claimed, error: claimError } = await admin.rpc("claim_bi_monthly_ledger_delivery", { _ledger_id: ledger.id, _lease_seconds: 120 });
  if (claimError) return { ok: false, delivery_status: "failed", error: "delivery_claim_failed" };
  if (claimed !== true) return { ok: true, duplicate_suppressed: true, delivery_status: "sending" };

  const signedPdfUrl = await createLedgerSignedUrl(admin, ledger.pdf_url);
  if (!signedPdfUrl) {
    await admin.from("bi_monthly_ledgers").update({ delivery_status: "failed", delivery_lease_until: null, last_delivery_error: "signed_url_unavailable" }).eq("id", ledger.id);
    return { ok: false, delivery_status: "failed", error: "signed_url_unavailable" };
  }

  const delivery = await sendSoftWhatsApp(phone, businessName, totalDue, deadline, signedPdfUrl);
  if (delivery.ok) {
    const { error: finalizeError } = await admin.from("bi_monthly_ledgers").update({
      delivery_status: "sent", delivery_lease_until: null, last_delivery_error: null,
      whatsapp_message_id: delivery.id, sent_at: new Date().toISOString(),
    }).eq("id", ledger.id);
    if (finalizeError) {
      console.error("[generate-rescue-ledger] sent delivery could not be finalized", finalizeError.message);
      return { ok: false, delivery_status: "sending", error: "delivery_finalization_uncertain", manual_reconciliation_required: true };
    }
    return { ok: true, delivery_status: "sent", whatsapp_message_id: delivery.id };
  }

  if (String(delivery.error || "").includes("uncertain")) {
    await admin.from("bi_monthly_ledgers").update({ last_delivery_error: delivery.error }).eq("id", ledger.id);
    return { ok: false, delivery_status: "sending", error: delivery.error, manual_reconciliation_required: true };
  }
  const { error: failError } = await admin.from("bi_monthly_ledgers").update({ delivery_status: "failed", delivery_lease_until: null, last_delivery_error: delivery.error || "provider_failed" }).eq("id", ledger.id);
  if (failError) return { ok: false, delivery_status: "sending", error: "delivery_finalization_uncertain", manual_reconciliation_required: true };
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
  try { body = (await req.json()) as RunArgs; } catch { body = {}; }

  try {
    const now = new Date();
    const ist = new Date(now.getTime() + 5.5 * 3600 * 1000);
    const startOfMonth = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth(), 1)).toISOString();
    const fallbackMonthEnd = new Date(Date.UTC(ist.getUTCFullYear(), ist.getUTCMonth() + 1, 0)).toISOString().slice(0, 10);

    let query = admin.from("companies").select("id, business_name, phone, total_outstanding, rescue_payment_date, settlement_deadline").eq("payment_terms", "credit");
    query = body.company_id ? query.eq("id", body.company_id) : query.gt("total_outstanding", 0);
    const { data: companies, error: companyError } = await query;
    if (companyError) throw companyError;
    const targets = (companies || []).filter((company: any) => Number(company.total_outstanding || 0) > 0 || (company.rescue_payment_date && company.rescue_payment_date >= startOfMonth));
    if (body.dry_run === true) return jsonResponse({ ok: true, dry_run: true, authorized_as: authority.kind, target_companies: targets.length });

    const results: Record<string, unknown>[] = [];
    let generated = 0;
    for (const company of targets) {
      const anchor = company.rescue_payment_date || startOfMonth;
      const periodStart = String(anchor).slice(0, 10);
      const periodEnd = company.settlement_deadline ? String(company.settlement_deadline).slice(0, 10) : fallbackMonthEnd;
      const { data: existing, error: existingError } = await admin.from("bi_monthly_ledgers")
        .select("id, pdf_url, whatsapp_message_id, delivery_status, delivery_attempt_count")
        .eq("company_id", company.id).eq("period_start", periodStart).eq("period_end", periodEnd).eq("ledger_kind", LEDGER_KIND).maybeSingle();
      if (existingError) throw existingError;
      if (existing) {
        const ledger = existing as LedgerRow;
        if (["sent", "skipped"].includes(ledger.delivery_status)) {
          results.push({ company_id: company.id, ok: true, duplicate_suppressed: true, ledger_id: ledger.id, delivery_status: ledger.delivery_status });
          continue;
        }
        if (ledger.delivery_status === "sending") {
          results.push({ company_id: company.id, ok: false, duplicate_suppressed: true, ledger_id: ledger.id, delivery_status: "sending", manual_reconciliation_required: true });
          continue;
        }
        const retry = await deliverLedger(admin, ledger, company.phone, company.business_name, Number(company.total_outstanding || 0), company.settlement_deadline);
        results.push({ company_id: company.id, ledger_id: ledger.id, retried: true, ...retry });
        continue;
      }

      const { data: orders, error: ordersError } = await admin.from("orders").select("id, sales_order_value, created_at")
        .eq("company_id", company.id).gte("created_at", anchor).not("status", "in", "(draft,cart,cancelled)").order("created_at", { ascending: true });
      if (ordersError) throw ordersError;
      const accruedRows = (orders || []).map((order: any) => ({ date: order.created_at, orderRef: `SO-${String(order.id).slice(0, 8).toUpperCase()}`, amount: Number(order.sales_order_value || 0) }));
      const accruedTotal = accruedRows.reduce((sum, row) => sum + row.amount, 0);
      const totalDue = Number(company.total_outstanding || 0);
      const rescueBalance = Math.max(0, totalDue - accruedTotal);
      const pdfBytes = await buildRescuePdf({ businessName: company.business_name, rescueBalance, rescuePaidOn: company.rescue_payment_date, accruedRows, accruedTotal, totalDue, settlementDeadline: company.settlement_deadline });
      const path = `rescue/${company.id}/${periodStart}_${periodEnd}.pdf`;
      const { error: uploadError } = await admin.storage.from(LEDGER_BUCKET).upload(path, pdfBytes, { contentType: "application/pdf", upsert: true });
      if (uploadError) { results.push({ company_id: company.id, ok: false, error: "pdf_upload_failed" }); continue; }

      const { data: ledger, error: ledgerError } = await admin.from("bi_monthly_ledgers").insert({
        company_id: company.id, period_start: periodStart, period_end: periodEnd, total_amount: totalDue,
        order_count: accruedRows.length, pdf_url: storageRef(path), status: "rescue_reminder", ledger_kind: LEDGER_KIND,
        delivery_status: "pending", delivery_attempt_count: 0, generated_by: authority.userId, sent_at: null,
      }).select("id, pdf_url, whatsapp_message_id, delivery_status, delivery_attempt_count").single();
      if (ledgerError) {
        if ((ledgerError as any).code === "23505") { results.push({ company_id: company.id, ok: true, duplicate_suppressed: true }); continue; }
        throw ledgerError;
      }
      generated += 1;
      const delivery = await deliverLedger(admin, ledger as LedgerRow, company.phone, company.business_name, totalDue, company.settlement_deadline);
      results.push({ company_id: company.id, ledger_id: ledger.id, rescue_balance: rescueBalance, accrued_order_value: accruedTotal, total_outstanding: totalDue, ...delivery });
    }
    return jsonResponse({ ok: true, generated, results });
  } catch (error) {
    console.error("[generate-rescue-ledger] failure", error instanceof Error ? error.message : "unknown");
    return jsonResponse({ ok: false, error: "internal_error" }, 500);
  }
});
