import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  isWaWebhookAutoOrderWritesEnabled,
  isWaWebhookOwnerReassignmentEnabled,
} from "../_shared/wa-governance/flags.ts";
import { fanOutToStudioInbox } from "../_shared/studioInboxFanOut.ts";

/** Service-role client from `createClient` — schema-generic, matches runtime usage in this edge function. */
type SupabaseAdminClient = SupabaseClient;

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, GET, OPTIONS",
};

const PORTAL_URL = Deno.env.get("B2B_PORTAL_URL") || "https://b2b.oasisbaklawa.com";
const CTA_FOOTER = `\n\nPlease login to your B2B Portal to track your 10-point artisan journey:\n${PORTAL_URL}`;

/** Items below this confidence trigger clarification hold (no PI until resolved). */
const CLARIFICATION_LOW_CONF = 0.6;
/** All parsed line items must meet this to clear hold via a short follow-up re-parse. */
const HOLD_RELEASE_CONF = 0.85;
const HELD_ORDER_MAX_AGE_MS = 72 * 60 * 60 * 1000;
const FOLLOWUP_PARSE_MAX_CHARS = 280;
const CONFIRM_FOLLOWUP_MAX_CHARS = 80;

/** Substrings that indicate order-ish commerce intent when paired with classifier output (see handler). */
const ORDER_INTENT_KEYWORDS = [
  "need", "order", "send", "want", "box", "boxes", "carton", "cartons",
  "kg", "pcs", "pieces", "rate", "price", "quote",
];

// ── PHONE HELPERS ──
function normalizePhone(raw: string): string {
  const digits = raw.replace(/[^0-9]/g, "");
  return digits.length >= 10 ? digits.slice(-10) : digits;
}

function to91(raw: string): string {
  const digits = raw.replace(/[^0-9]/g, "");
  if (digits.length === 10) return `91${digits}`;
  if (digits.length === 12 && digits.startsWith("91")) return digits;
  return digits;
}

// Lightweight company-name extraction (mirror of frontend banyan-parser).
function extractCompanyNameFromText(text: string): string | null {
  if (!text) return null;
  const patterns = [
    /(?:from|for|m\/s\.?|client|company)\s*[:\-]?\s*([A-Z][A-Za-z0-9 &.\-]{2,40})/i,
    /([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+){0,3})\s+(?:traders|enterprises|sweets|foods|catering|hotel|restaurant|stores|paharganj|bakery)/i,
  ];
  for (const re of patterns) {
    const m = text.match(re);
    if (m?.[1]) return m[1].trim();
  }
  return null;
}

// ── SENDER CLASSIFICATION ──
async function classifySender(
  phone10: string,
  supabaseAdmin: any
): Promise<{ type: "staff" | "client" | "lead"; userId?: string; role?: string; name?: string; isSalesExec?: boolean }> {
  const { data: staffMatch } = await supabaseAdmin
    .from("users")
    .select("id, role, name, full_name, phone, mobile_number, is_sales_executive")
    .or(`phone.ilike.%${phone10},mobile_number.ilike.%${phone10}`)
    .limit(1);

  if (staffMatch && staffMatch.length > 0) {
    const user = staffMatch[0];
    const role = (user.role || "").toUpperCase();
    const isSalesExec = !!user.is_sales_executive;
    const staffRoles = [
      "SUPER_ADMIN", "ADMIN", "FINANCE_HEAD", "FINANCE_EXEC",
      "OPERATIONS_MANAGER", "PRODUCTION_MANAGER", "SALES_EXECUTIVE",
      "SUPPORT_EXECUTIVE", "DISPATCH_MANAGER", "STORE_INCHARGE",
    ];
    if (staffRoles.some((r) => role.includes(r)) || isSalesExec) {
      return { type: "staff", userId: user.id, role, name: user.full_name || user.name, isSalesExec };
    }
    return { type: "client", userId: user.id, name: user.full_name || user.name, isSalesExec };
  }
  return { type: "lead" };
}

// ── AI PRODUCT PARSING (Lovable AI Gateway) ──
async function aiParseOrder(
  messageBody: string,
  products: { id: string; name: string; sku?: string | null }[],
  aliases: { alias_text: string; canonical_name: string; product_id?: string | null }[]
): Promise<{
  items: { productId: string; productName: string; quantity: number; confidence: number }[];
  businessInfo: { name?: string; address?: string; gst?: string; city?: string } | null;
}> {
  const apiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!apiKey) {
    console.log("LOVABLE_API_KEY not set, falling back to rule-based parsing");
    return { items: [], businessInfo: null };
  }

  const productList = products.slice(0, 100).map((p) => `${p.name} (SKU: ${p.sku || "N/A"})`).join("\n");
  const aliasList = aliases.slice(0, 50).map((a) => `"${a.alias_text}" → "${a.canonical_name}"`).join("\n");

  const prompt = `You are an order parser for Oasis Baklawa (a B2B wholesale bakery). Parse the following WhatsApp message into structured order items and business info.

PRODUCT CATALOG:
${productList}

KNOWN ALIASES:
${aliasList}

MESSAGE:
"${messageBody}"

Return JSON ONLY:
{
  "items": [{"product_name": "exact catalog name", "quantity": number, "confidence": 0.0-1.0}],
  "business_info": {"name": "if mentioned", "address": "if mentioned", "gst": "GST number if mentioned", "city": "if mentioned"} or null
}

Rules:
- Match misspelled/abbreviated product names to the closest catalog item
- Use aliases mapping when possible
- If quantity is unclear, default to 1 with confidence 0.5
- confidence: 1.0 = exact match, 0.7+ = high, 0.4-0.7 = medium, <0.4 = low
- Extract any business details (name, address, GST) from the message`;

  try {
    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "google/gemini-3-flash-preview",
        messages: [{ role: "user", content: prompt }],
        response_format: { type: "json_object" },
        max_tokens: 1000,
      }),
    });

    if (!res.ok) {
      console.error(`AI Gateway error: ${res.status}`);
      return { items: [], businessInfo: null };
    }

    const data = await res.json();
    const content = data.choices?.[0]?.message?.content || "{}";
    const parsed = JSON.parse(content);

    const mappedItems = (parsed.items || []).map((item: any) => {
      const match = products.find(
        (p) => p.name.toLowerCase() === (item.product_name || "").toLowerCase()
      ) || products.find(
        (p) => p.name.toLowerCase().includes((item.product_name || "").toLowerCase())
      ) || products.find(
        (p) => (item.product_name || "").toLowerCase().includes(p.name.toLowerCase())
      );

      return match
        ? { productId: match.id, productName: match.name, quantity: item.quantity || 1, confidence: item.confidence || 0.5 }
        : null;
    }).filter(Boolean);

    return { items: mappedItems, businessInfo: parsed.business_info || null };
  } catch (e) {
    console.error("AI parse error:", e);
    return { items: [], businessInfo: null };
  }
}

// ── RULE-BASED FALLBACK ──
function aliasMatchProduct(
  text: string,
  products: { id: string; name: string; sku?: string | null }[],
  aliases: { alias_text: string; canonical_name: string; product_id?: string | null }[]
): { id: string; name: string } | null {
  const lower = text.toLowerCase();

  for (const alias of aliases) {
    if (lower.includes(alias.alias_text.toLowerCase())) {
      if (alias.product_id) {
        const p = products.find((pr) => pr.id === alias.product_id);
        if (p) return { id: p.id, name: p.name };
      }
      const p = products.find((pr) => pr.name.toLowerCase() === alias.canonical_name.toLowerCase());
      if (p) return { id: p.id, name: p.name };
      const partial = products.find((pr) => pr.name.toLowerCase().includes(alias.canonical_name.toLowerCase()));
      if (partial) return { id: partial.id, name: partial.name };
    }
  }

  for (const p of products) {
    if (p.sku && lower.includes(p.sku.toLowerCase())) return { id: p.id, name: p.name };
  }
  for (const p of products) {
    if (lower.includes(p.name.toLowerCase())) return { id: p.id, name: p.name };
  }

  let bestScore = 0;
  let bestProduct: { id: string; name: string } | null = null;
  for (const p of products) {
    const words = p.name.toLowerCase().split(/\s+/).filter((w) => w.length > 2);
    const score = words.filter((w) => lower.includes(w)).length;
    if (score >= 2 && score > bestScore) {
      bestScore = score;
      bestProduct = { id: p.id, name: p.name };
    }
  }
  return bestProduct;
}

function parseQuantity(text: string): number {
  const patterns = [
    /(\d+)\s*(?:box|boxes|carton|cartons|pcs|pieces|kg|packs?)/i,
    /(?:need|send|want|order)\s*(\d+)/i,
    /(\d+)\s+(?:of|nos?|units?)/i,
  ];
  for (const pat of patterns) {
    const m = text.match(pat);
    if (m) return parseInt(m[1], 10);
  }
  return 1;
}

// ── RULE-BASED INTENT CLASSIFICATION ──
// Pure function — no DB calls, no AI, no side effects.
// Evaluated in priority order: later checks only run if earlier ones do not match.
// Returns one of the canonical intent strings used as message_intent in debug_webhooks.
function classifyMessageIntent(
  messageBody: string,
  messageType: string,
  mediaMime: string
): string {
  const t = (messageBody || "").toLowerCase().trim();
  const mt = (messageType || "").toLowerCase();
  const mm = (mediaMime || "").toLowerCase();

  // ── Tier 1: media type signals (highest priority) ──
  if ((mt === "document" || mm.includes("pdf")) && t.length < 500) {
    return "PURCHASE_ORDER_DOCUMENT";
  }

  // ── Tier 2: explicit keyword sets ──

  // Internal / admin pings — narrow: bare "test"/"testing" in prose must NOT match (e.g. lab test, send test samples).
  const trimmed = (messageBody || "").trim();
  if (
    /\b(ignore this|internal message|internal note|admin note)\b/i.test(t) ||
    /^(test|testing)[\s.!?]*$/i.test(trimmed)
  ) {
    return "INTERNAL_NOTE";
  }

  // Cancellation — check before modification to avoid "cancel changes" mis-classifying
  if (/\b(cancel|cancellation|don't send|do not send|hold order|stop order|ruk jao|band karo|mat bhejo)\b/i.test(t)) {
    return "ORDER_CANCELLATION";
  }

  // Order modification
  if (/\b(change|modify|update order|replace|add more|reduce|increase|edit order|correction in order|order correction|update the order)\b/i.test(t)) {
    return "ORDER_MODIFICATION";
  }

  // Complaint
  if (/\b(complaint|complain|damaged|broken|wrong item|wrong quantity|missing item|not received|short delivery|quality issue|mouldy|stale|expired|rotten|not as ordered|bad quality|defective|contaminated)\b/i.test(t)) {
    return "COMPLAINT";
  }

  // Payment proof
  if (
    /\b(paid|payment done|transferred|neft|rtgs|upi|gpay|phone ?pe|paytm|bank transfer|transaction id|utr|reference no|attached payment|bhej diya|payment kar diya|amount sent)\b/i.test(t) ||
    (mt === "image" && /\b(payment|paid|transfer|receipt|transaction)\b/i.test(t))
  ) {
    return "PAYMENT_PROOF";
  }

  // KYC / identity documents
  if (/\b(gst certificate|fssai|pan card|aadhaar|aadhar|kyc|registration certificate|trade license|drug license)\b/i.test(t)) {
    return "CLIENT_KYC_DOCUMENT";
  }

  // SO / invoice reference
  if (/\b(order number|sales order|so number|invoice|inv no|tcf|my previous order|same as before|repeat (?:my )?order|reference|last (?:time |week )?order|previous order)\b/i.test(t)) {
    return "SO_REFERENCE";
  }

  // Dispatch follow-up
  if (/\b(dispatch|dispatched|tracking|when (?:will|is|does) (?:my )?(?:order|delivery)|kab aayega|delivery status|where is my order|lr number|transporter|awb|docket|out for delivery|truck|vehicle)\b/i.test(t)) {
    return "DISPATCH_FOLLOWUP";
  }

  // Packaging material inquiry — checked before ORDER to prevent spurious SOs.
  // Suppress only when there is no quantity/order pattern (e.g. "send empty box 10 pcs" stays eligible for ORDER downstream).
  const packagingContext =
    /\b(acrylic (?:box|jar|tray)|empty (?:box|jar|tray|carton)|packing material|packaging material|cavity tray|tart shell|shell|box only|just (?:box|jar|tray)|carton only)\b/i.test(t);
  if (packagingContext) {
    const looksLikePackagingQtyOrder =
      /\d+\s*(?:pcs|pieces|nos\.?|units?|boxes|cartons?)/i.test(t) ||
      /\b(?:empty\s+)?(?:box|jar|tray|carton|cavity\s+tray|acrylic\s+(?:jar|box|tray))\s+\d+/i.test(t);
    if (!looksLikePackagingQtyOrder) {
      return "PACKAGING_MATERIAL_REQUEST";
    }
  }

  // General inquiry — price / catalogue / policy
  if (/\b(price list|rate list|catalogue|catalog|what do you have|product list|minimum order|moq|delivery time|terms and conditions|return policy|rate (?:hai|kya|batao)|kya hai|kya milta)\b/i.test(t)) {
    return "GENERAL_INQUIRY";
  }

  // Falls through to ORDER if orderKeywords are present (checked at call site)
  return "OTHER";
}

// ── SEND WHATSAPP REPLY ──
async function sendReply(phone: string, message: string, supabaseAdmin: any, companyId?: string | null) {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  if (!apiKey) return;

  const fullMessage = message + CTA_FOOTER;

  const digits = phone.replace(/[^0-9]/g, "");
  const apiPhone = digits.length === 10 ? `91${digits}` : digits;

  try {
    const res = await fetch("https://crm.click2api.in/api/v1/messages", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "apikey": apiKey,
        ...(accessToken ? { "Authorization": `Bearer ${accessToken}` } : {}),
      },
      body: JSON.stringify({
        messaging_product: "whatsapp",
        to: apiPhone,
        type: "text",
        text: { body: fullMessage },
      }),
    });
    console.log(`Reply sent to ${apiPhone}: ${res.status}`);

    await supabaseAdmin.from("debug_webhooks").insert({
      direction: "outbound",
      raw_payload: { to: apiPhone, message: fullMessage.substring(0, 500), status: res.status },
      phone_number: apiPhone,
      processed: res.ok,
    });

    if (companyId) {
      await supabaseAdmin.from("client_interactions").insert({
        company_id: companyId,
        interaction_type: "whatsapp",
        notes: `[AUTO_REPLY] ${fullMessage.substring(0, 500)}`,
        outcome: res.ok ? "delivered" : "failed",
      });
    }
  } catch (e) {
    console.error("Reply send error:", e);
  }
}

// ── GENERATE TEXT-BASED PI ──
function generateTextPI(orderId: string, companyName: string, items: { name: string; qty: number }[], totalEstimate: number): string {
  const soNum = orderId.split("-")[0].toUpperCase();
  const lines = [
    `PROFORMA INVOICE`,
    ``,
    `SO #: ${soNum}`,
    `Client: ${companyName}`,
    `Date: ${new Date().toLocaleDateString("en-IN", { day: "2-digit", month: "short", year: "numeric", timeZone: "Asia/Kolkata" })}`,
    ``,
    `Items:`,
  ];

  items.forEach((item, i) => {
    lines.push(`${i + 1}. ${item.name} x ${item.qty}`);
  });

  lines.push(``);
  if (totalEstimate > 0) {
    const advance = Math.max(Math.round((totalEstimate * 0.2) / 1000) * 1000, 1000);
    lines.push(`Estimated Value: Rs. ${totalEstimate.toLocaleString("en-IN")}`);
    lines.push(`Advance Required (20%): Rs. ${advance.toLocaleString("en-IN")}`);
  } else {
    lines.push(`Pricing will be confirmed by your Sales Executive.`);
  }

  lines.push(``);
  lines.push(`Track your order: ${PORTAL_URL}/track?token=${orderId}`);
  lines.push(``);
  lines.push(`Status: Pre-Approved | Advance Pending`);
  lines.push(``);
  lines.push(`— Oasis Operations`);

  return lines.join("\n");
}

type ParsedOrderItem = { productId: string; productName: string; quantity: number; confidence: number };

async function findHeldClarificationOrder(
  supabaseAdmin: SupabaseAdminClient,
  companyId: string,
): Promise<{ id: string } | null> {
  const cutoff = new Date(Date.now() - HELD_ORDER_MAX_AGE_MS).toISOString();
  const { data } = await supabaseAdmin
    .from("orders")
    .select("id")
    .eq("company_id", companyId)
    .eq("needs_clarification", true)
    .eq("status", "awaiting_clarification")
    .or("is_waste.is.null,is_waste.eq.false")
    .gte("created_at", cutoff)
    .order("created_at", { ascending: false })
    .limit(1)
    .maybeSingle();
  return data?.id ? { id: data.id } : null;
}

/** Strict: no digits (avoid qty corrections), short, confirmation-only phrasing. */
function isConfirmOnlyFollowup(text: string): boolean {
  const t = text.trim().toLowerCase().replace(/[.!?,]+$/g, "").replace(/\s+/g, " ");
  if (!t || t.length > CONFIRM_FOLLOWUP_MAX_CHARS) return false;
  if (/\d/.test(t)) return false;
  const allowed = new Set([
    "yes", "yep", "yeah", "ok", "okay",
    "confirmed", "confirm", "proceed", "correct",
    "go ahead", "thats fine", "that's fine", "fine",
    "noted", "approved", "alright", "all right",
  ]);
  if (allowed.has(t)) return true;
  const words = t.split(/\s+/);
  return words.length === 1 && allowed.has(words[0]);
}

async function sendPiNotificationsAndCrm(args: {
  supabaseAdmin: SupabaseAdminClient;
  draftOrderId: string;
  companyName: string;
  phone91: string;
  companyId: string;
  accountManagerId: string | null;
  messageBody: string;
  piItems: { name: string; qty: number }[];
  totalWithGst: number;
  isShadowClient: boolean;
  crmOutcome: string;
  crmNotesSuffix: string;
}): Promise<boolean> {
  const {
    supabaseAdmin, draftOrderId, companyName, phone91, companyId, accountManagerId,
    messageBody, piItems, totalWithGst, isShadowClient, crmOutcome, crmNotesSuffix,
  } = args;

  let piSent = false;
  if (piItems.length > 0) {
    const piText = generateTextPI(draftOrderId, companyName, piItems, totalWithGst);
    await sendReply(phone91, piText, supabaseAdmin, companyId);
    piSent = true;
    console.log(`PI sent to ${phone91} for order ${draftOrderId}`);
  } else {
    const ackMsg = [
      `Oasis Operations has created your draft sales order.`,
      ``,
      `Reference: SO #${draftOrderId.split("-")[0].toUpperCase()}`,
      ``,
      `Our team will share the next update shortly.`,
      ``,
      `— Oasis Operations`,
    ].join("\n");
    await sendReply(phone91, ackMsg, supabaseAdmin, companyId);
  }

  if (accountManagerId) {
    await supabaseAdmin.from("notifications").insert({
      user_id: accountManagerId,
      type: "whatsapp_order",
      message: `New WhatsApp Draft Order from ${companyName}${piItems.length > 0 ? ` - ${piItems.map((i) => `${i.name} x ${i.qty}`).join(", ")}` : ""}. Review now.`,
      is_read: false,
    });
  }

  const { data: admins } = await supabaseAdmin
    .from("users").select("id")
    .in("role", ["admin", "super_admin", "ADMIN", "SUPER_ADMIN"])
    .limit(5);
  for (const admin of admins || []) {
    if (admin.id === accountManagerId) continue;
    await supabaseAdmin.from("notifications").insert({
      user_id: admin.id,
      type: "whatsapp_order",
      message: `WhatsApp Draft from ${companyName}: "${messageBody.substring(0, 100)}"`,
      is_read: false,
    });
  }

  await supabaseAdmin.from("client_interactions").insert({
    company_id: companyId,
    executive_id: accountManagerId,
    interaction_type: "whatsapp",
    notes: `[SYSTEM_AI] ${crmNotesSuffix} ${isShadowClient ? "Shadow client." : ""} ${piSent ? "PI sent via WhatsApp." : ""}`,
    outcome: crmOutcome,
  });

  return piSent;
}

async function resolveHeldOrderConfirm(args: {
  supabaseAdmin: SupabaseAdminClient;
  heldOrderId: string;
  companyName: string;
  phone91: string;
  companyId: string;
  accountManagerId: string | null;
  messageBody: string;
  products: { id: string; name: string; sku?: string | null; base_price?: number | null; price_b2b?: number | null; price_per_kg?: number | null; wholesale_price?: number | null; price_wholesale?: number | null }[];
  isShadowClient: boolean;
}): Promise<boolean> {
  const { supabaseAdmin, heldOrderId, companyName, phone91, companyId, accountManagerId, messageBody, products, isShadowClient } = args;

  const { data: rows } = await supabaseAdmin
    .from("order_items")
    .select("product_id, quantity")
    .eq("order_id", heldOrderId);
  if (!rows || rows.length === 0) return false;

  let estimatedTotal = 0;
  const piItems: { name: string; qty: number }[] = [];
  for (const row of rows) {
    const prod = products.find((p) => p.id === row.product_id);
    const name = prod?.name || "Item";
    const qty = Number(row.quantity) || 0;
    piItems.push({ name, qty });
    if (prod) {
      const price = prod.price_b2b || prod.base_price || prod.price_per_kg || prod.wholesale_price || prod.price_wholesale || 0;
      estimatedTotal += price * qty;
    }
  }

  const minConf = 1;
  const totalWithGst = Math.round(estimatedTotal * 1.18);
  const advanceRequired = Math.max(Math.round((totalWithGst * 0.2) / 1000) * 1000, 1000);

  await supabaseAdmin.from("orders").update({
    needs_clarification: false,
    status: "draft",
    parser_confidence: minConf,
    sales_order_value: totalWithGst,
    advance_required: advanceRequired,
  }).eq("id", heldOrderId);

  await sendPiNotificationsAndCrm({
    supabaseAdmin,
    draftOrderId: heldOrderId,
    companyName,
    phone91,
    companyId,
    accountManagerId,
    messageBody,
    piItems,
    totalWithGst,
    isShadowClient,
    crmOutcome: "clarification_resolved",
    crmNotesSuffix: `Clarification hold cleared (customer confirm). Order ${heldOrderId.slice(0, 8)}. Items: ${piItems.map((i) => `${i.name} x ${i.qty}`).join(", ")}.`,
  });

  return true;
}

async function resolveHeldOrderHighConfParse(args: {
  supabaseAdmin: SupabaseAdminClient;
  heldOrderId: string;
  companyName: string;
  phone91: string;
  companyId: string;
  accountManagerId: string | null;
  messageBody: string;
  orderItems: ParsedOrderItem[];
  products: { id: string; name: string; sku?: string | null; base_price?: number | null; price_b2b?: number | null; price_per_kg?: number | null; wholesale_price?: number | null; price_wholesale?: number | null }[];
  isShadowClient: boolean;
}): Promise<boolean> {
  const { supabaseAdmin, heldOrderId, companyName, phone91, companyId, accountManagerId, messageBody, orderItems, products, isShadowClient } = args;

  await supabaseAdmin.from("order_items").delete().eq("order_id", heldOrderId);

  let estimatedTotal = 0;
  const piItems: { name: string; qty: number }[] = [];
  const minConf = Math.min(...orderItems.map((i) => i.confidence));

  for (const item of orderItems) {
    await supabaseAdmin.from("order_items").insert({
      order_id: heldOrderId,
      product_id: item.productId,
      quantity: item.quantity,
      notes: `WhatsApp AI (confidence: ${(item.confidence * 100).toFixed(0)}%): "${messageBody.substring(0, 200)}"`,
    });
    const prod = products.find((p) => p.id === item.productId);
    if (prod) {
      const price = prod.price_b2b || prod.base_price || prod.price_per_kg || prod.wholesale_price || prod.price_wholesale || 0;
      estimatedTotal += price * item.quantity;
    }
    piItems.push({ name: item.productName, qty: item.quantity });
  }

  const totalWithGst = Math.round(estimatedTotal * 1.18);
  const advanceRequired = Math.max(Math.round((totalWithGst * 0.2) / 1000) * 1000, 1000);

  await supabaseAdmin.from("orders").update({
    needs_clarification: false,
    status: "draft",
    parser_confidence: minConf,
    sales_order_value: totalWithGst,
    advance_required: advanceRequired,
  }).eq("id", heldOrderId);

  await sendPiNotificationsAndCrm({
    supabaseAdmin,
    draftOrderId: heldOrderId,
    companyName,
    phone91,
    companyId,
    accountManagerId,
    messageBody,
    piItems,
    totalWithGst,
    isShadowClient,
    crmOutcome: "clarification_resolved",
    crmNotesSuffix: `Clarification hold cleared (high-confidence follow-up parse). Order ${heldOrderId.slice(0, 8)}. Items: ${piItems.map((i) => `${i.name} x ${i.qty}`).join(", ")}.`,
  });

  return true;
}

// ── PDF / DOCUMENT PARSING ──
async function parseDocumentForRepeatOrder(
  attachmentUrl: string,
  supabaseAdmin: any
): Promise<{ invoiceRef: string | null; items: { name: string; qty: number }[] }> {
  const result: { invoiceRef: string | null; items: { name: string; qty: number }[] } = {
    invoiceRef: null,
    items: [],
  };

  try {
    const apiKey = Deno.env.get("LOVABLE_API_KEY");
    if (!apiKey) return result;

    const prompt = `You are a document parser for Oasis Baklawa. The customer has sent a previous invoice or purchase order document.

Extract the following from the document URL/reference: ${attachmentUrl}

Return JSON ONLY:
{
  "invoice_ref": "TCF/25-26/XXXX or similar reference number, or null",
  "items": [{"name": "product name as written", "qty": number}]
}

Look for:
- Invoice numbers in TCF/YY-YY/NNNN format
- Product names and quantities from line items
- Any SKU codes`;

    const res = await fetch("https://openrouter.ai/api/v1/chat/completions", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "Authorization": `Bearer ${apiKey}`,
      },
      body: JSON.stringify({
        model: "google/gemini-3-flash-preview",
        messages: [{ role: "user", content: prompt }],
        response_format: { type: "json_object" },
        max_tokens: 1000,
      }),
    });

    if (res.ok) {
      const data = await res.json();
      const content = data.choices?.[0]?.message?.content || "{}";
      const parsed = JSON.parse(content);
      result.invoiceRef = parsed.invoice_ref || null;
      result.items = (parsed.items || []).map((i: any) => ({
        name: i.name || "",
        qty: i.qty || 1,
      }));
    }
  } catch (e) {
    console.error("Document parse error:", e);
  }

  return result;
}

// ── PAYLOAD EXTRACTION ──
function extractPayloadFields(payload: any) {
  const entry = payload?.entry?.[0]?.changes?.[0]?.value;
  if (entry) {
    const msg = entry?.messages?.[0];
    const contact = entry?.contacts?.[0];
    return {
      senderPhone: msg?.from || contact?.wa_id || "",
      messageBody: msg?.text?.body || msg?.caption || "",
      messageType: msg?.type || "text",
      mediaUrl: msg?.image?.url || msg?.image?.link || msg?.document?.url || msg?.document?.link || msg?.video?.url || null,
      mediaMime: msg?.image?.mime_type || msg?.document?.mime_type || "image/jpeg",
      messageId: msg?.id || null,
      profileName: contact?.profile?.name || null,
      timestampSec: msg?.timestamp ?? null,
    };
  }

  const m91 =
    payload?.payload?.message ? payload.payload :
    payload?.data?.payload?.message ? payload.data.payload :
    payload?.payload && (payload.payload?.mobile || payload.payload?.from || payload.payload?.sender) ? payload.payload :
    null;
  if (m91) {
    const message = m91.message || {};
    const media = message.media || message.image || message.document || message.video || null;
    const text =
      message.text?.body || message.text || message.caption || media?.caption || m91.text || "";
    return {
      senderPhone: m91.mobile || m91.from || m91.sender || m91.contact?.wa_id || "",
      messageBody: typeof text === "string" ? text : (text?.body || ""),
      messageType: message.type || m91.type || (media ? "image" : "text"),
      mediaUrl: media?.url || media?.link || media?.media_url || null,
      mediaMime: media?.mime_type || media?.mimeType || "image/jpeg",
      messageId: m91._id || m91.id || m91.message_id || message.id || null,
      profileName: m91.sender_name || m91.name || m91.contact?.profile?.name || null,
      timestampSec: m91.timestamp ?? message.timestamp ?? null,
    };
  }

  return {
    senderPhone: payload?.from || payload?.sender || payload?.mobile || payload?.data?.from || payload?.contact?.wa_id || payload?.waId || "",
    messageBody: payload?.message || payload?.body || payload?.data?.body || payload?.text?.body || payload?.text || "",
    messageType: payload?.messageType || payload?.type || payload?.data?.type || "text",
    mediaUrl: payload?.mediaUrl || payload?.media_url || payload?.data?.media_url ||
      payload?.image?.url || payload?.document?.url || payload?.data?.image?.url || null,
    mediaMime: payload?.mediaMimeType || payload?.media_mime_type ||
      payload?.image?.mime_type || payload?.document?.mime_type || "image/jpeg",
    messageId: payload?.messageId || payload?.id || payload?.message_id || null,
    profileName: payload?.pushName || payload?.profileName || payload?.contact?.name || payload?.sender_name || null,
    timestampSec: payload?.timestamp ?? payload?.data?.timestamp ?? null,
  };
}

async function findOrCreateWhatsappContact(
  supabaseAdmin: SupabaseAdminClient,
  phoneDigits: string,
  waContactId?: string | null,
): Promise<string | null> {
  if (!phoneDigits) return null;
  try {
    const existing = await supabaseAdmin
      .from("whatsapp_contacts")
      .select("id")
      .eq("phone_number", phoneDigits)
      .maybeSingle();
    if (existing.data?.id) return existing.data.id;

    const created = await supabaseAdmin
      .from("whatsapp_contacts")
      .insert({
        phone_number: phoneDigits,
        wa_contact_id: waContactId || phoneDigits,
      })
      .select("id")
      .single();
    if (created.error) {
      console.warn("[whatsapp-webhook] whatsapp_contacts insert:", created.error.message);
      return null;
    }
    return created.data?.id ?? null;
  } catch (e) {
    console.warn("[whatsapp-webhook] findOrCreateWhatsappContact:", e);
    return null;
  }
}

function triggerMessageStitcherNonBlocking(): void {
  const baseUrl = Deno.env.get("SUPABASE_URL")?.replace(/\/$/, "");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!baseUrl || !serviceKey) return;
  void fetch(`${baseUrl}/functions/v1/whatsapp-message-stitcher`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Authorization": `Bearer ${serviceKey}`,
    },
    body: JSON.stringify({ trigger: "webhook" }),
  }).catch((err) =>
    console.warn(`[whatsapp-webhook] Stitcher call failed (non-blocking): ${err}`)
  );
}

// ══════════════════════════════════════════════════
// MAIN HANDLER
// ══════════════════════════════════════════════════
serve(async (req) => {
  if (req.method === "GET") {
    const url = new URL(req.url);
    const queryEntries = Array.from(url.searchParams.entries());
    console.log(`Handshake Query Params: ${JSON.stringify(queryEntries)}`);
    const challengeParamNames = ["challange", "challenge", "hub.challenge", "hub_challenge"];
    const tokenParamNames = ["echo", "hub.verify_token", "verify_token"];
    const challengeEntry = queryEntries.find(([key]) => challengeParamNames.includes(key.toLowerCase()));
    const tokenEntries = queryEntries.filter(([key]) => tokenParamNames.includes(key.toLowerCase()));
    if (tokenEntries.length > 0) {
      console.log(`Handshake Token Candidates: [${tokenEntries.map(([k, v]) => `${k}=${v}`).join(", ")}]`);
    }
    if (challengeEntry) {
      console.log(`Handshake Successful: Responding to [${challengeEntry[0]}] with value [${challengeEntry[1]}]`);
      return new Response(challengeEntry[1], { status: 200, headers: { "Content-Type": "text/plain; charset=utf-8" } });
    }
    return new Response("Oasis OS Webhook Active", { status: 200, headers: { "Content-Type": "text/plain; charset=utf-8" } });
  }

  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!
  );

  try {
    const waAutoOrderWritesEnabled = isWaWebhookAutoOrderWritesEnabled((k) => Deno.env.get(k));
    const waOwnerReassignmentEnabled = isWaWebhookOwnerReassignmentEnabled((k) => Deno.env.get(k));

    const payload = await req.json();
    console.log("Incoming WhatsApp webhook:", JSON.stringify(payload).substring(0, 1000));

    const { senderPhone, messageBody, messageType, mediaUrl, mediaMime, messageId, profileName, timestampSec } =
      extractPayloadFields(payload);

    const last10 = normalizePhone(senderPhone);
    const phone91 = to91(senderPhone);

    const noiseTypes = new Set(["reaction", "unsupported", "system", "ephemeral", "sticker_reaction"]);
    const isNoise = noiseTypes.has((messageType || "").toLowerCase());
    const isEmpty = !messageBody && !mediaUrl;
    if (isNoise || isEmpty) {
      try {
        await supabaseAdmin.from("debug_webhooks").insert({
          direction: "inbound",
          raw_payload: payload,
          phone_number: phone91 || senderPhone || null,
          wamid: messageId || null,
          processed: true,
          discard_reason: isNoise ? `noise_${messageType}` : "empty_body",
          error_message: isNoise ? `Discarded ${messageType} (no order intent)` : "Empty payload — nothing to parse",
        });
      } catch (_) { /* best-effort log */ }
      return new Response(JSON.stringify({ ok: true, discarded: isNoise ? messageType : "empty" }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (messageId) {
      const { data: existingWamid } = await supabaseAdmin
        .from("debug_webhooks")
        .select("id")
        .eq("wamid", messageId)
        .limit(1)
        .maybeSingle();
      if (existingWamid?.id) {
        console.log(`[WAMID_DEDUP] Discarding duplicate wamid=${messageId}`);
        await supabaseAdmin.from("debug_webhooks").insert({
          direction: "inbound",
          raw_payload: payload,
          phone_number: phone91 || senderPhone || null,
          wamid: messageId,
          processed: true,
          discard_reason: "duplicate_wamid",
          error_message: `Duplicate WhatsApp message ID — original webhook ${existingWamid.id}`,
        });
        return new Response(JSON.stringify({ ok: true, discarded: "duplicate_wamid" }), {
          status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    const { data: webhookRow } = await supabaseAdmin.from("debug_webhooks").insert({
      direction: "inbound",
      raw_payload: payload,
      phone_number: phone91 || senderPhone || null,
      wamid: messageId || null,
      error_message: null,
      processed: false,
    }).select("id").maybeSingle();

    // ── BANYAN BUFFER: stash this message for the Central Parser (60s debounce) ──
    if (last10 && (messageBody || mediaUrl)) {
      try {
        await supabaseAdmin.from("whatsapp_buffer").insert({
          sender_phone: last10,
          sender_name: profileName,
          message_type: messageType || "text",
          text_content: messageBody || null,
          media_url: mediaUrl,
          media_mime_type: mediaMime,
          raw_payload: payload,
          webhook_id: (webhookRow as any)?.id || null,
          bundle_status: "pending",
        });
      } catch (bufErr) {
        console.error("Buffer insert error:", bufErr);
      }
    }


    // ── STUDIO INBOX FAN-OUT (read-only; failures must not break legacy ERP path) ──
    if (
      messageId &&
      messageBody?.trim() &&
      (messageType || "").toLowerCase() === "text"
    ) {
      void fanOutToStudioInbox({
        supabaseAdmin,
        providerMessageId: messageId,
        senderPhone: phone91,
        senderName: profileName,
        messageBody,
        rawPayload: payload,
        timestampSec,
      });
    }

    // ── INTENT CLASSIFICATION ──
    const messageIntentRaw = classifyMessageIntent(
      messageBody || "",
      messageType || "",
      mediaMime || ""
    );

    let messageIntent = messageIntentRaw;
    let hasOrderIntent = false;
    if (messageIntentRaw !== "INTERNAL_NOTE") {
      const msgLowerForOrder = (messageBody || "").toLowerCase();
      hasOrderIntent =
        messageIntentRaw !== "PACKAGING_MATERIAL_REQUEST" &&
        ORDER_INTENT_KEYWORDS.some((kw) => msgLowerForOrder.includes(kw));
      if (messageIntentRaw === "OTHER" && hasOrderIntent) {
        messageIntent = "ORDER";
      }
    }

    console.log(`[INTENT] ${messageIntent} | phone=${phone91} | type=${messageType}`);

    if ((webhookRow as any)?.id) {
      void supabaseAdmin
        .from("debug_webhooks")
        .update({ message_intent: messageIntent })
        .eq("id", (webhookRow as any).id)
        .then(
          () => { /* no-op */ },
          (e: unknown) => console.error("intent write failed:", e),
        );
    }

    if (messageIntentRaw === "INTERNAL_NOTE") {
      if ((webhookRow as any)?.id) {
        await supabaseAdmin
          .from("debug_webhooks")
          .update({ processed: true, discard_reason: "internal_note" })
          .eq("id", (webhookRow as any).id);
      }
      return new Response(JSON.stringify({ ok: true, intent: "INTERNAL_NOTE", skipped: true }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    try {
      const txt = (messageBody || "").toLowerCase().trim();
      const isDispute =
        txt.includes("request correction") ||
        txt.includes("ledger dispute") ||
        txt.includes("ledger correction") ||
        txt.includes("account mismatch") ||
        txt === "disputed" ||
        txt === "dispute";
      if (last10 && isDispute) {
        const { data: comp } = await supabaseAdmin
          .from("companies")
          .select("id, business_name")
          .or(`phone.ilike.%${last10}`)
          .limit(1)
          .maybeSingle();
        if (comp?.id) {
          const { data: latestLedger } = await supabaseAdmin
            .from("bi_monthly_ledgers")
            .select("id")
            .eq("company_id", comp.id)
            .order("generated_at", { ascending: false })
            .limit(1)
            .maybeSingle();
          if (latestLedger?.id) {
            await supabaseAdmin.from("ledger_disputes").insert({
              ledger_id: latestLedger.id,
              company_id: comp.id,
              raised_via: "whatsapp",
              description: messageBody?.slice(0, 500) || null,
              status: "open",
            });
            await supabaseAdmin
              .from("bi_monthly_ledgers")
              .update({ status: "disputed" })
              .eq("id", latestLedger.id);
            const apiKey = Deno.env.get("CLICK2API_API_KEY");
            const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
            if (apiKey) {
              await fetch("https://crm.click2api.in/api/v1/messages", {
                method: "POST",
                headers: {
                  "Content-Type": "application/json",
                  apikey: apiKey,
                  ...(accessToken ? { Authorization: `Bearer ${accessToken}` } : {}),
                },
                body: JSON.stringify({
                  messaging_product: "whatsapp",
                  to: phone91,
                  type: "text",
                  text: {
                    body:
                      `Oasis Operations has received your account discrepancy request.\n\nOur Finance team has been notified and will review your ledger with you shortly.\n\n— Oasis Operations`,
                  },
                }),
              }).catch(() => {});
            }
          }
        }
      }
    } catch (dispErr) {
      console.error("Dispute keyword detection error:", dispErr);
    }

    const direction: string = (payload?.direction as string) || (payload?.statuses ? "status" : "");
    if (direction === "outgoing" || direction === "sent" || direction === "status") {
      if (payload?.statuses) {
        console.log("Status update received, skipping:", JSON.stringify(payload.statuses).substring(0, 200));
      }
      return new Response(JSON.stringify({ ok: true, skipped: "outgoing/status" }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    try {
      if (phone91 && (messageBody || mediaUrl)) {
        const contactId = await findOrCreateWhatsappContact(supabaseAdmin, phone91, phone91);
        if (contactId) {
          const tsSec =
            timestampSec != null && timestampSec !== ""
              ? Number(timestampSec)
              : NaN;
          const message_timestamp =
            Number.isFinite(tsSec) && tsSec > 0
              ? new Date(tsSec * 1000)
              : new Date();

          const { error: insertError } = await supabaseAdmin
            .from("whatsapp_messages")
            .insert({
              contact_id: contactId,
              order_id: null,
              direction: "inbound",
              message_type: messageType || "text",
              content: messageBody || "",
              media_url: mediaUrl || null,
              provider: "whatsapp",
              provider_message_id: messageId,
              status: "received",
              message_timestamp,
              is_raw: true,
              packet_id: null,
            })
            .select("id")
            .single();

          if (!insertError) {
            triggerMessageStitcherNonBlocking();
          } else {
            console.warn("[whatsapp-webhook] whatsapp_messages insert failed:", insertError);
          }
        }
      }
    } catch (wmErr) {
      console.warn("[whatsapp-webhook] whatsapp_messages / stitcher block failed:", wmErr);
    }

    if (!senderPhone && !mediaUrl) {
      return new Response(JSON.stringify({ ok: true, skipped: "no sender" }), {
        status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    const sender = await classifySender(last10, supabaseAdmin);
    console.log(`Sender classified: ${sender.type} (${sender.name || "unknown"}) phone=${phone91}, isSalesExec=${sender.isSalesExec}`);

    let companyId: string | null = null;
    let companyName = profileName || "Unknown";
    let accountManagerId: string | null = null;
    let isShadowClient = false;

    const senderIsStaffProxy = sender.type === "staff" && !!sender.userId;
    const senderIsSalesExec = sender.type === "staff" && sender.isSalesExec && sender.userId;
    let companyResolutionLocked = false;

    if (senderIsStaffProxy && messageBody) {
      const clientPatterns = [
        /(?:order\s+for|client|customer|party|for\s+M\/s\.?|for)\s+[:\-]?\s*([A-Z][A-Za-z\s&'.]+)/i,
        /([A-Z][A-Za-z\s&'.]{3,})\s+(?:ka|ke|ki|order|wants?|need)/i,
      ];
      let mentionedClient: string | null = null;
      for (const pat of clientPatterns) {
        const m = messageBody.match(pat);
        if (m) { mentionedClient = m[1].trim(); break; }
      }

      if (mentionedClient) {
        const { data: clientMatch } = await supabaseAdmin
          .from("companies")
          .select("id, business_name, account_manager_id")
          .ilike("business_name", `%${mentionedClient}%`)
          .limit(1);

        if (clientMatch && clientMatch.length > 0) {
          companyId = clientMatch[0].id;
          companyName = clientMatch[0].business_name;
          accountManagerId = clientMatch[0].account_manager_id ?? null;
          companyResolutionLocked = true;
          if (
            waOwnerReassignmentEnabled &&
            !clientMatch[0].account_manager_id &&
            sender.userId
          ) {
            await supabaseAdmin.from("companies")
              .update({ account_manager_id: sender.userId })
              .eq("id", companyId);
            accountManagerId = sender.userId;
            console.log(
              `[WA-GOV] Owner reassignment enabled: assigned ${sender.name} as account manager for ${companyId}`,
            );
          } else if (!clientMatch[0].account_manager_id) {
            console.log(
              `[WA-GOV] Client owner unset for company ${companyId}; automatic account_manager assignment skipped (ENABLE_WA_WEBHOOK_OWNER_REASSIGNMENT=false)`,
            );
          }
          console.log(`Staff re-wire: ${sender.name} -> order for client "${companyName}" (${companyId})`);
        }
      }
    }

    if (!companyResolutionLocked) {
      const { data: apps } = await supabaseAdmin
        .from("b2b_applications")
        .select("id, business_name, user_id, contact_phone, mobile_number")
        .or(`contact_phone.ilike.%${last10},mobile_number.ilike.%${last10}`)
        .eq("status", "approved")
        .limit(1);

      if (apps && apps.length > 0) {
        companyName = apps[0].business_name;
        const { data: companies } = await supabaseAdmin
          .from("companies")
          .select("id, account_manager_id")
          .eq("business_name", apps[0].business_name)
          .limit(1);
        if (companies && companies.length > 0) {
          companyId = companies[0].id;
          accountManagerId = companies[0].account_manager_id;
        }
      }
    }

    if (!companyId) {
      const { data: userMatch } = await supabaseAdmin
        .from("users")
        .select("id, company_id, name, full_name")
        .or(`phone.ilike.%${last10},mobile_number.ilike.%${last10}`)
        .limit(1);

      if (userMatch && userMatch.length > 0 && userMatch[0].company_id) {
        companyId = userMatch[0].company_id;
        const { data: comp } = await supabaseAdmin
          .from("companies")
          .select("business_name, account_manager_id")
          .eq("id", companyId)
          .single();
        if (comp) {
          companyName = comp.business_name;
          accountManagerId = comp.account_manager_id;
        }
      }
    }

    if (!companyId) {
      const { data: phoneMatch } = await supabaseAdmin
        .from("companies")
        .select("id, business_name, account_manager_id, status")
        .ilike("gst_number", `%${last10}%`)
        .order("status", { ascending: true })
        .limit(1);

      if (phoneMatch && phoneMatch.length > 0) {
        companyId = phoneMatch[0].id;
        companyName = phoneMatch[0].business_name;
        accountManagerId = phoneMatch[0].account_manager_id;
        isShadowClient = phoneMatch[0].status === "shadow";
      }
    }

    try {
      const candidateName = extractCompanyNameFromText(messageBody || "");
      if (candidateName && last10) {
        const { data: realCompany } = await supabaseAdmin
          .from("companies")
          .select("id, business_name, account_manager_id, status")
          .ilike("business_name", `%${candidateName}%`)
          .neq("status", "shadow")
          .limit(1)
          .maybeSingle();

        if (realCompany?.id) {
          const cutoff = new Date(Date.now() - 180 * 1000).toISOString();
          const { data: shadowCompanies } = await supabaseAdmin
            .from("companies")
            .select("id")
            .eq("status", "shadow")
            .ilike("gst_number", `%${last10}%`)
            .limit(5);
          const shadowIds = (shadowCompanies || []).map((c: any) => c.id);
          if (shadowIds.length > 0) {
            const { data: recentShadowOrder } = await supabaseAdmin
              .from("orders")
              .select("id")
              .in("company_id", shadowIds)
              .gte("created_at", cutoff)
              .order("created_at", { ascending: false })
              .limit(1)
              .maybeSingle();
            if (recentShadowOrder?.id) {
              if (waAutoOrderWritesEnabled) {
                await supabaseAdmin
                  .from("orders")
                  .update({ company_id: realCompany.id })
                  .eq("id", recentShadowOrder.id);
                console.log(`[CONTEXT STITCH] Retargeted order ${recentShadowOrder.id} → ${realCompany.business_name} via "${candidateName}"`);
              } else {
                console.log(
                  `[WA-GOV] Context stitch order retarget skipped for ${recentShadowOrder.id} (ENABLE_WA_WEBHOOK_AUTO_ORDER_WRITES=false)`,
                );
              }
              companyId = realCompany.id;
              companyName = realCompany.business_name;
              accountManagerId = realCompany.account_manager_id;
              isShadowClient = false;
              if (senderIsStaffProxy) companyResolutionLocked = true;
            }
          }
        }
      }
    } catch (stitchErr) {
      console.error("Context stitching failed:", stitchErr);
    }

    if (!companyId && senderPhone && !senderIsStaffProxy) {
      const shadowName = profileName ? `${profileName} (WhatsApp)` : `WhatsApp Lead ${phone91}`;

      const { data: newCompany, error: compErr } = await supabaseAdmin
        .from("companies")
        .insert({
          business_name: shadowName,
          status: "shadow",
          gst_number: `WA:${phone91}`,
          price_tier: "B2B",
        })
        .select("id")
        .single();

      if (!compErr && newCompany) {
        companyId = newCompany.id;
        companyName = shadowName;
        isShadowClient = true;
        console.log(`Shadow client created: ${shadowName} (${companyId})`);

        const { data: admins } = await supabaseAdmin
          .from("users").select("id")
          .in("role", ["admin", "super_admin", "ADMIN", "SUPER_ADMIN"])
          .limit(5);
        for (const admin of admins || []) {
          await supabaseAdmin.from("notifications").insert({
            user_id: admin.id,
            type: "shadow_client",
            message: `New Shadow Client: ${shadowName} (${phone91}). Verify and onboard in the Verification War Room.`,
            is_read: false,
          });
        }
      }
    }
    if (!companyId && senderIsStaffProxy) {
      console.log(`Proxy staff sender unresolved: ${sender.name || sender.userId} phone=${phone91} (shadow creation skipped)`);
    }

    if (
      senderIsSalesExec &&
      companyId &&
      !accountManagerId &&
      waOwnerReassignmentEnabled &&
      sender.userId
    ) {
      accountManagerId = sender.userId;
      await supabaseAdmin.from("companies")
        .update({ account_manager_id: sender.userId })
        .eq("id", companyId);
      console.log(`[WA-GOV] Owner reassignment enabled: auto-assigned ${sender.name} as account manager for ${companyId}`);
    } else if (senderIsSalesExec && companyId && !accountManagerId) {
      console.log(
        `[WA-GOV] Sales exec ${sender.name} proxy for ${companyId}; owner assignment skipped (ENABLE_WA_WEBHOOK_OWNER_REASSIGNMENT=false)`,
      );
    }

    console.log(`Mapped phone ${phone91} -> company: ${companyName} (${companyId}), shadow: ${isShadowClient}, sender: ${sender.type}, salesExec: ${senderIsSalesExec}`);

    let attachmentUrl: string | null = null;
    let documentParseResult: { invoiceRef: string | null; items: { name: string; qty: number }[] } | null = null;

    if (mediaUrl) {
      try {
        const apiKey = Deno.env.get("CLICK2API_API_KEY");
        const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
        const mediaRes = await fetch(mediaUrl, {
          headers: {
            ...(apiKey ? { "apikey": apiKey } : {}),
            ...(accessToken ? { "Authorization": `Bearer ${accessToken}` } : {}),
          },
        });
        if (mediaRes.ok) {
          const blob = await mediaRes.arrayBuffer();
          const ext = mediaMime.includes("pdf") ? "pdf" : mediaMime.includes("png") ? "png" : "jpg";
          const filePath = `${last10}/${Date.now()}.${ext}`;
          const { error: uploadErr } = await supabaseAdmin.storage
            .from("whatsapp_attachments")
            .upload(filePath, new Uint8Array(blob), { contentType: mediaMime, upsert: false });
          if (!uploadErr) {
            const { data: urlData } = supabaseAdmin.storage.from("whatsapp_attachments").getPublicUrl(filePath);
            attachmentUrl = urlData?.publicUrl || filePath;
            if ((webhookRow as any)?.id && attachmentUrl) {
              try {
                await supabaseAdmin
                  .from("debug_webhooks")
                  .update({
                    raw_payload: { ...(payload as any), _oasis_attachment_url: attachmentUrl },
                  } as any)
                  .eq("id", (webhookRow as any).id);
              } catch (patchErr) {
                console.error("debug_webhooks attachment patch failed:", patchErr);
              }
            }
          }

          if (messageType === "document" || mediaMime.includes("pdf")) {
            documentParseResult = await parseDocumentForRepeatOrder(attachmentUrl || filePath, supabaseAdmin);
            if (documentParseResult.invoiceRef) {
              console.log(`Document parsed: Invoice Ref ${documentParseResult.invoiceRef}, Items: ${documentParseResult.items.length}`);
            }
          }
        } else {
          await mediaRes.text();
        }
      } catch (mediaErr) {
        console.error("Media download failed:", mediaErr);
      }
    }

    const interactionNotes = [
      `[INCOMING${sender.type === "staff" ? " - STAFF: " + sender.name : ""}]`,
      messageBody ? messageBody.substring(0, 1000) : "(media only)",
      attachmentUrl ? `\nAttachment: ${attachmentUrl}` : "",
      isShadowClient ? `\nShadow Client - pending verification` : "",
      documentParseResult?.invoiceRef ? `\nRepeat Order Ref: ${documentParseResult.invoiceRef}` : "",
    ].filter(Boolean).join(" ");

    if (companyId) {
      await supabaseAdmin.from("client_interactions").insert({
        company_id: companyId,
        executive_id: accountManagerId,
        interaction_type: "whatsapp",
        notes: interactionNotes,
        outcome: "received",
      });
    }

    let draftOrderId: string | null = null;
    let piSent = false;

    if (hasOrderIntent && companyId && messageBody) {
      if (!waAutoOrderWritesEnabled) {
        console.log(
          `[WA-GOV] Pipeline C auto-order skipped for company ${companyId} (ENABLE_WA_WEBHOOK_AUTO_ORDER_WRITES=false). Inbound capture + Banyan buffer path unchanged.`,
        );
      } else {
      const { data: allProducts } = await supabaseAdmin
        .from("products")
        .select("id, name, sku, base_price, price_b2b, price_wholesale, wholesale_price, price_per_kg")
        .limit(500);

      const { data: aliasRows } = await supabaseAdmin
        .from("product_aliases")
        .select("alias_text, canonical_name, product_id")
        .limit(200);

      const products = allProducts || [];
      const aliases = aliasRows || [];

      console.log(`Products loaded: ${products.length}, Aliases loaded: ${aliases.length}`);

      let skipNewOrderPipeline = false;

      const heldEarly = await findHeldClarificationOrder(supabaseAdmin, companyId);
      if (heldEarly?.id) {
        const trimmed = messageBody.trim();
        let resolvedHere = false;

        if (isConfirmOnlyFollowup(trimmed)) {
          resolvedHere = await resolveHeldOrderConfirm({
            supabaseAdmin,
            heldOrderId: heldEarly.id,
            companyName,
            phone91,
            companyId,
            accountManagerId,
            messageBody,
            products,
            isShadowClient,
          });
        } else if (trimmed.length > 0 && trimmed.length <= FOLLOWUP_PARSE_MAX_CHARS) {
          const fuAi = await aiParseOrder(trimmed, products, aliases);
          let fuItems: ParsedOrderItem[] = fuAi.items;
          if (fuItems.length === 0) {
            const matched = aliasMatchProduct(trimmed, products, aliases);
            const qty = parseQuantity(trimmed);
            if (matched) {
              fuItems = [{ productId: matched.id, productName: matched.name, quantity: qty, confidence: 0.7 }];
            }
          }
          if (fuItems.length > 0 && fuItems.every((i) => i.confidence >= HOLD_RELEASE_CONF)) {
            resolvedHere = await resolveHeldOrderHighConfParse({
              supabaseAdmin,
              heldOrderId: heldEarly.id,
              companyName,
              phone91,
              companyId,
              accountManagerId,
              messageBody: trimmed,
              orderItems: fuItems,
              products,
              isShadowClient,
            });
          }
        }

        if (resolvedHere) {
          draftOrderId = heldEarly.id;
          piSent = true;
          skipNewOrderPipeline = true;
        } else {
          const neutralHold = [
            `Oasis Operations is still clarifying your pending order (ref ${heldEarly.id.slice(0, 8).toUpperCase()}).`,
            ``,
            `Please reply to our earlier WhatsApp message with the requested details, or send a brief confirmation if the information is already correct.`,
            ``,
            `— Oasis Operations`,
          ].join("\n");
          await sendReply(phone91, neutralHold, supabaseAdmin, companyId);
          skipNewOrderPipeline = true;
        }
      }

      if (!skipNewOrderPipeline) {
        const aiResult = await aiParseOrder(messageBody, products, aliases);
        let orderItems: ParsedOrderItem[] = aiResult.items;

        if (orderItems.length === 0) {
          const matched = aliasMatchProduct(messageBody, products, aliases);
          const qty = parseQuantity(messageBody);
          console.log(`Rule-based match: ${matched ? matched.name : "NONE"}, qty: ${qty}`);
          if (matched) {
            orderItems = [{ productId: matched.id, productName: matched.name, quantity: qty, confidence: 0.7 }];
          }
        }

        if (documentParseResult && documentParseResult.items.length > 0) {
          for (const docItem of documentParseResult.items) {
            const matched = aliasMatchProduct(docItem.name, products, aliases);
            if (matched && !orderItems.find((oi) => oi.productId === matched.id)) {
              orderItems.push({
                productId: matched.id,
                productName: matched.name,
                quantity: docItem.qty,
                confidence: 0.8,
              });
            }
          }
        }

        console.log(`Order items resolved: ${orderItems.length}`);

        if (isShadowClient && companyId) {
          const bizInfo = aiResult.businessInfo;
          if (bizInfo) {
            const updates: Record<string, any> = {};
            if (bizInfo.name) updates.business_name = bizInfo.name;
            if (bizInfo.gst && /\d{2}[A-Z]{5}\d{4}[A-Z]{1}\d{1}[A-Z]{1}\d{1}/.test(bizInfo.gst)) {
              updates.gst_number = bizInfo.gst;
            }
            if (bizInfo.address) updates.website = bizInfo.address;
            if (Object.keys(updates).length > 0) {
              await supabaseAdmin.from("companies").update(updates).eq("id", companyId);
              console.log(`Shadow data auto-filled: ${JSON.stringify(updates)}`);
            }
          }
          if (profileName && !aiResult.businessInfo?.name) {
            await supabaseAdmin.from("companies")
              .update({ business_name: `${profileName} (WhatsApp)` })
              .eq("id", companyId)
              .eq("business_name", `WhatsApp Lead ${phone91}`);
          }
        }

        const lowConfidenceItems = orderItems.filter((i) => i.confidence < CLARIFICATION_LOW_CONF);

        if (lowConfidenceItems.length > 0 && orderItems.length > 0) {
          const clarificationLines = lowConfidenceItems.map(
            (i) => `- "${i.productName}" x ${i.quantity}`,
          );
          const clarifyMsg = [
            `Oasis Operations has logged your order request and requires one clarification before sharing pricing:`,
            ``,
            `Please confirm the specific variant or quantity for:`,
            ``,
            ...clarificationLines,
            ``,
            `Please reply with corrections, or send a brief confirmation if the above is correct.`,
            ``,
            `— Oasis Operations`,
          ].join("\n");

          await sendReply(phone91, clarifyMsg, supabaseAdmin, companyId);
          console.log(`Clarification hold: outbound clarification only (${lowConfidenceItems.length} low-confidence lines)`);

          const minParserConf = Math.min(...orderItems.map((i) => i.confidence));
          let heldTargetId: string | null = null;
          const existingHeld = await findHeldClarificationOrder(supabaseAdmin, companyId);

          if (existingHeld?.id) {
            heldTargetId = existingHeld.id;
            await supabaseAdmin.from("order_items").delete().eq("order_id", heldTargetId);
            await supabaseAdmin.from("orders").update({
              needs_clarification: true,
              status: "awaiting_clarification",
              parser_confidence: minParserConf,
              dispatch_urgency: "standard",
              payment_status: "awaiting_advance",
            }).eq("id", heldTargetId);
          } else {
            const { data: ins, error: insErr } = await supabaseAdmin
              .from("orders")
              .insert({
                company_id: companyId,
                status: "awaiting_clarification",
                needs_clarification: true,
                parser_confidence: minParserConf,
                dispatch_urgency: "standard",
                payment_status: "awaiting_advance",
              })
              .select("id")
              .single();
            if (!insErr && ins?.id) heldTargetId = ins.id;
          }

          if (heldTargetId) {
            draftOrderId = heldTargetId;
            let estimatedTotal = 0;
            const piItems: { name: string; qty: number }[] = [];

            for (const item of orderItems) {
              await supabaseAdmin.from("order_items").insert({
                order_id: heldTargetId,
                product_id: item.productId,
                quantity: item.quantity,
                notes: `WhatsApp AI (confidence: ${(item.confidence * 100).toFixed(0)}%): "${messageBody.substring(0, 200)}"`,
              });
              const prod = products.find((p) => p.id === item.productId);
              if (prod) {
                const price = prod.price_b2b || prod.base_price || prod.price_per_kg || prod.wholesale_price || prod.price_wholesale || 0;
                estimatedTotal += price * item.quantity;
              }
              piItems.push({ name: item.productName, qty: item.quantity });
            }

            const totalWithGst = Math.round(estimatedTotal * 1.18);
            const advanceRequired = Math.max(Math.round((totalWithGst * 0.2) / 1000) * 1000, 1000);
            await supabaseAdmin.from("orders").update({
              sales_order_value: totalWithGst,
              advance_required: advanceRequired,
            }).eq("id", heldTargetId);

            if (accountManagerId) {
              await supabaseAdmin.from("notifications").insert({
                user_id: accountManagerId,
                type: "whatsapp_order",
                message: `WhatsApp order awaiting clarification from ${companyName}${piItems.length > 0 ? ` — ${piItems.map((i) => `${i.name} x ${i.qty}`).join(", ")}` : ""}. No PI sent yet.`,
                is_read: false,
              });
            }

            const { data: adminsHold } = await supabaseAdmin
              .from("users").select("id")
              .in("role", ["admin", "super_admin", "ADMIN", "SUPER_ADMIN"])
              .limit(5);
            for (const admin of adminsHold || []) {
              if (admin.id === accountManagerId) continue;
              await supabaseAdmin.from("notifications").insert({
                user_id: admin.id,
                type: "whatsapp_order",
                message: `Clarification hold: ${companyName} — "${messageBody.substring(0, 100)}"`,
                is_read: false,
              });
            }

            await supabaseAdmin.from("client_interactions").insert({
              company_id: companyId,
              executive_id: accountManagerId,
              interaction_type: "whatsapp",
              notes: `[SYSTEM_AI] Clarification hold ${heldTargetId.slice(0, 8)}. ${piItems.length > 0 ? `Items: ${piItems.map((i) => `${i.name} x ${i.qty}`).join(", ")}.` : ""} ${isShadowClient ? "Shadow client." : ""} Parser min conf ${(minParserConf * 100).toFixed(0)}%. No PI sent.`,
              outcome: existingHeld?.id ? "clarification_hold_updated" : "clarification_hold",
            });
          }
        } else if (orderItems.length > 0 || hasOrderIntent) {
          console.log(`Creating draft order for ${companyId}, items: ${orderItems.length}`);
          const { data: draftOrder, error: orderErr } = await supabaseAdmin
            .from("orders")
            .insert({
              company_id: companyId,
              status: "draft",
              dispatch_urgency: "standard",
              payment_status: "awaiting_advance",
            })
            .select("id")
            .single();

          console.log(`Draft result: ${JSON.stringify(draftOrder)}, err: ${orderErr?.message || "none"}`);
          if (!orderErr && draftOrder) {
            draftOrderId = draftOrder.id;

            let estimatedTotal = 0;
            const piItems: { name: string; qty: number }[] = [];

            for (const item of orderItems) {
              await supabaseAdmin.from("order_items").insert({
                order_id: draftOrder.id,
                product_id: item.productId,
                quantity: item.quantity,
                notes: `WhatsApp AI (confidence: ${(item.confidence * 100).toFixed(0)}%): "${messageBody.substring(0, 200)}"`,
              });

              const prod = products.find((p) => p.id === item.productId);
              if (prod) {
                const price = prod.price_b2b || prod.base_price || prod.price_per_kg || prod.wholesale_price || prod.price_wholesale || 0;
                estimatedTotal += price * item.quantity;
              }
              piItems.push({ name: item.productName, qty: item.quantity });
            }

            if (orderItems.length === 0) {
              await supabaseAdmin.from("debug_webhooks").insert({
                direction: "inbound",
                raw_payload: { message: messageBody, sender: senderPhone, company: companyName },
                phone_number: phone91,
                error_message: `No SKU Match: ${messageBody.substring(0, 500)}`,
                processed: false,
              });
            }

            const totalWithGst = Math.round(estimatedTotal * 1.18);
            const advanceRequired = Math.max(Math.round((totalWithGst * 0.2) / 1000) * 1000, 1000);

            await supabaseAdmin.from("orders").update({
              sales_order_value: totalWithGst,
              advance_required: advanceRequired,
              parser_confidence: orderItems.length > 0 ? Math.min(...orderItems.map((i) => i.confidence)) : null,
            }).eq("id", draftOrder.id);

            piSent = await sendPiNotificationsAndCrm({
              supabaseAdmin,
              draftOrderId: draftOrder.id,
              companyName,
              phone91,
              companyId,
              accountManagerId,
              messageBody,
              piItems,
              totalWithGst,
              isShadowClient,
              crmOutcome: "draft_order_created",
              crmNotesSuffix: `Draft order ${draftOrder.id.slice(0, 8)} auto-created. ${piItems.length > 0 ? `Items: ${piItems.map((i) => `${i.name} x ${i.qty}`).join(", ")}.` : "No SKU match - manual review."}`,
            });
          }
        }
      }
      }
    } else if (messageBody && companyId && !hasOrderIntent) {
      let ackMsg: string;
      if (messageIntent === "PAYMENT_PROOF") {
        ackMsg = [
          `Oasis Operations has received your payment proof.`,
          ``,
          `Our Finance team will verify and update your account within one working day.`,
          ``,
          `— Oasis Operations`,
        ].join("\n");
      } else if (messageIntent === "COMPLAINT") {
        ackMsg = [
          `Oasis Operations has received your complaint.`,
          ``,
          `Our team has been notified and will review and respond within 24 hours.`,
          ``,
          `— Oasis Operations`,
        ].join("\n");
      } else if (messageIntent === "DISPATCH_FOLLOWUP") {
        ackMsg = [
          `Oasis Operations has received your dispatch follow-up request.`,
          ``,
          `Our Logistics team will share the latest shipment status shortly.`,
          ``,
          `— Oasis Operations`,
        ].join("\n");
      } else if (messageIntent === "PACKAGING_MATERIAL_REQUEST") {
        ackMsg = [
          `Oasis Operations has received your packaging material request.`,
          ``,
          `Our team will review availability and respond shortly.`,
          ``,
          `— Oasis Operations`,
        ].join("\n");
      } else {
        ackMsg = [
          `Oasis Operations has received your message.`,
          ``,
          `Our team will review and respond shortly.`,
          ``,
          `— Oasis Operations`,
        ].join("\n");
      }
      await sendReply(phone91, ackMsg, supabaseAdmin, companyId);
    }

    if (waAutoOrderWritesEnabled) {
      const cutoff48h = new Date(Date.now() - 48 * 60 * 60 * 1000).toISOString();
      const { data: staleDrafts } = await supabaseAdmin
        .from("orders")
        .select("id")
        .eq("status", "draft")
        .lte("sales_order_value", 0)
        .lt("created_at", cutoff48h)
        .limit(50);

      if (staleDrafts && staleDrafts.length > 0) {
        const staleIds = staleDrafts.map((d: any) => d.id);
        await supabaseAdmin.from("orders").update({ status: "cancelled" }).in("id", staleIds);
        console.log(`Archived ${staleIds.length} stale draft orders`);
      }
    }

    return new Response(
      JSON.stringify({
        ok: true,
        company: companyName,
        company_id: companyId,
        sender_type: sender.type,
        message_intent: messageIntent,
        order_intent: hasOrderIntent,
        draft_order_id: draftOrderId,
        pi_sent: piSent,
        attachment: attachmentUrl,
        shadow_client: isShadowClient,
        document_parsed: !!documentParseResult?.invoiceRef,
      }),
      { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } }
    );
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Unexpected error";
    console.error("whatsapp-webhook error:", msg);

    try {
      await supabaseAdmin.from("debug_webhooks").insert({
        direction: "inbound",
        raw_payload: { error: msg },
        error_message: msg,
        processed: false,
      });
    } catch { /* swallow */ }

    return new Response(JSON.stringify({ error: msg }), {
      status: 500,
      headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});

