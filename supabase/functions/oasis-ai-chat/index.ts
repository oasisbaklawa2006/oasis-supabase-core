import { createClient } from "npm:@supabase/supabase-js@2.45.0";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Cache-Control": "no-store",
  "Pragma": "no-cache",
  "X-Content-Type-Options": "nosniff",
};

const SYSTEM_PROMPT = `You are "Oasis Assistant", the official AI concierge for Oasis Baklawa B2B (TCF Chocolates & Gifts Pvt. Ltd.).

Tone: warm, concise, premium. Use plain language. Never invent SKUs or prices.

Authoritative knowledge:
- Shelf life: 90 days from manufacturing (all baklawa SKUs).
- Storage: ambient, cool & dry. Avoid direct sunlight. No refrigeration required.
- Ingredients: premium grade — pure ghee, A-grade pistachios, cashews, almonds, saffron, rosewater. No preservatives, no palm oil.
- Category C MOQ: cartons require exactly 9 packs. Minimum 3 packs per variant. Valid mixes: 9, 6+3, 5+4, 3+3+3.
- Starter Packs (admin-curated, 3 tiers): Basic (~₹15k), Smart (~₹35k), Premium (~₹75k). Available in Growth Intelligence modal for first-time buyers; carton-fill rules are waived for these.
- Credit: bi-monthly ledger, 70% rescue unlock, month-end auto-freeze on outstanding > 0.
- If user asks about a price, route them to the catalogue or their Account Manager.
- If user reports an issue with an order, ask for the SO number and offer to escalate.
- If unsure, say so plainly; never fabricate.`;

function json(status: number, body: Record<string, unknown>): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function bearer(req: Request): string | null {
  const raw = req.headers.get("Authorization") ?? "";
  if (!raw.startsWith("Bearer ")) return null;
  const token = raw.slice(7).trim();
  return token || null;
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: corsHeaders });
  if (req.method !== "POST") return json(405, { error: "method_not_allowed" });

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  if (!supabaseUrl || !serviceRoleKey) return json(503, { error: "service_unavailable" });

  const token = bearer(req);
  if (!token) return json(401, { error: "unauthorized" });

  const admin = createClient(supabaseUrl, serviceRoleKey, { auth: { persistSession: false } });
  const { data: authData, error: authError } = await admin.auth.getUser(token);
  const userId = authData.user?.id ?? null;
  if (authError || !userId) return json(401, { error: "unauthorized" });

  const { data: isStaff, error: staffError } = await admin.rpc("is_internal_staff", { _user_id: userId });
  if (staffError) {
    console.error("[oasis-ai-chat] staff authority lookup failed", staffError.message);
    return json(503, { error: "authority_unavailable" });
  }
  if (isStaff !== true) return json(403, { error: "forbidden" });

  let rawBody: unknown;
  try {
    rawBody = await req.json();
  } catch {
    return json(400, { error: "invalid_json" });
  }
  const input = rawBody as { messages?: unknown };
  if (!Array.isArray(input.messages) || input.messages.length < 1 || input.messages.length > 20) {
    return json(400, { error: "invalid_messages" });
  }

  const messages: Array<{ role: "user" | "assistant"; content: string }> = [];
  for (const item of input.messages) {
    if (!item || typeof item !== "object") return json(400, { error: "invalid_messages" });
    const role = (item as Record<string, unknown>).role;
    const content = (item as Record<string, unknown>).content;
    if ((role !== "user" && role !== "assistant") || typeof content !== "string") {
      return json(400, { error: "invalid_messages" });
    }
    const normalized = content.trim();
    if (!normalized || normalized.length > 8000) return json(400, { error: "invalid_messages" });
    messages.push({ role, content: normalized });
  }

  const lovableApiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!lovableApiKey) return json(503, { error: "ai_gateway_not_configured" });

  try {
    const resp = await fetch("https://ai.gateway.lovable.dev/v1/chat/completions", {
      method: "POST",
      signal: AbortSignal.timeout(30_000),
      headers: {
        Authorization: `Bearer ${lovableApiKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        model: "google/gemini-2.5-flash",
        stream: true,
        messages: [{ role: "system", content: SYSTEM_PROMPT }, ...messages],
      }),
    });

    if (resp.status === 429) return json(429, { error: "rate_limited" });
    if (resp.status === 402) return json(402, { error: "ai_credits_exhausted" });
    if (!resp.ok || !resp.body) {
      console.error("[oasis-ai-chat] AI gateway rejected request", resp.status);
      return json(502, { error: "ai_gateway_failed" });
    }

    return new Response(resp.body, {
      status: 200,
      headers: {
        ...corsHeaders,
        "Content-Type": "text/event-stream",
        Connection: "keep-alive",
      },
    });
  } catch (error) {
    const timedOut = error instanceof DOMException && error.name === "TimeoutError";
    console.error("[oasis-ai-chat] AI gateway request failed", timedOut ? "timeout" : "network_error");
    return json(timedOut ? 504 : 502, { error: timedOut ? "ai_gateway_timeout" : "ai_gateway_unreachable" });
  }
});
