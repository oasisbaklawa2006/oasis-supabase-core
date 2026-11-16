import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "npm:@supabase/supabase-js@2.45.0";

const CONFIDENCE_THRESHOLD = 0.85;
const BULK_DEFAULT_BOX_KG = 6;
const BULK_DEFAULT_GRAMS_PER_PIECE = 22;

function generateHexToken(bytes = 16): string {
  const arr = new Uint8Array(bytes);
  crypto.getRandomValues(arr);
  return Array.from(arr).map((b) => b.toString(16).padStart(2, "0")).join("");
}

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

interface IncomingItem {
  name: string;
  quantity?: number;
  unit?: string | null;
  confidence?: number;
}

function convertToKg(qty: number, rawUnit: string | null | undefined, product: any): number | null {
  if (!Number.isFinite(qty) || qty <= 0) return null;
  const u = (rawUnit || "").toLowerCase().trim();
  const isBulk = (product?.category || "").toLowerCase().includes("bulk");
  const boxKg = product?.weight_per_box_kg ?? (isBulk ? BULK_DEFAULT_BOX_KG : null);
  const gPp = product?.grams_per_piece ?? (isBulk ? BULK_DEFAULT_GRAMS_PER_PIECE : null);

  if (["kg", "kgs", "kilogram", "kilograms"].includes(u)) return qty;
  if (["gm", "g", "gms", "gram", "grams"].includes(u)) return qty / 1000;
  if (["box", "boxes", "carton", "cartons", "ctn", "ctns"].includes(u)) return boxKg ? qty * boxKg : null;
  if (["pc", "pcs", "piece", "pieces", "unit", "units"].includes(u)) return gPp ? (qty * gPp) / 1000 : null;
  // Bare number → assume Kg for Bulk only
  return isBulk ? qty : null;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: corsHeaders });

  const supabaseAdmin = createClient(
    Deno.env.get("SUPABASE_URL")!,
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  );

  const authHeader = req.headers.get("Authorization");
  if (!authHeader) {
    return new Response(JSON.stringify({ error: "Unauthorized" }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const token = authHeader.replace("Bearer ", "");
  const { data: { user }, error: authErr } = await supabaseAdmin.auth.getUser(token);
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: "Invalid token" }), {
      status: 401, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  const { data: userData } = await supabaseAdmin
    .from("users")
    .select("role")
    .eq("id", user.id)
    .single();

  const role = (userData?.role || "").toUpperCase();
  if (!["ADMIN", "SUPER_ADMIN"].includes(role)) {
    return new Response(JSON.stringify({ error: "Forbidden" }), {
      status: 403, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }

  try {
    const body = await req.json();
    const {
      company_id,
      phone,                    // sender phone (Sales Exec, NOT client)
      sku_names,                // legacy: string[] — confidence assumed 1.0
      sku_items,                // new: IncomingItem[] with qty/unit/confidence
      candidate_company_name,   // new: scanned business name from message
      webhook_id,
      webhook_ids,
      wamid,                    // WhatsApp message ID for idempotency
      activate_company,
      company_update,
      send_whatsapp_to,
      whatsapp_message,
    } = body;

    // --- WAMID IDEMPOTENCY: short-circuit if order already exists for this message ---
    if (wamid) {
      const { data: existingByWamid, error: wamidLookupError } = await supabaseAdmin
        .from("orders")
        .select("id, company_id, status, total_weight_kg, parser_confidence, needs_clarification, is_duplicate")
        .eq("wamid", wamid)
        .limit(1)
        .maybeSingle();
      if (wamidLookupError) {
        // A failed dedup lookup is not evidence that the message is new.
        // Never create another order after an uncertain WAMID read.
        return new Response(JSON.stringify({ error: "WAMID_LOOKUP_UNAVAILABLE" }), {
          status: 503, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
      if (existingByWamid?.id) {
        console.log(`[admin-create-draft] WAMID ${wamid} already processed → returning existing order ${existingByWamid.id}`);
        return new Response(JSON.stringify({
          ok: true,
          deduped: "wamid",
          order_id: existingByWamid.id,
          ...existingByWamid,
          whatsapp_notification_status: send_whatsapp_to || whatsapp_message
            ? "NOT_SENT_RELEASE_GATED"
            : "NOT_REQUESTED",
        }), { status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" } });
      }
    }

    let resolvedCompanyId: string | null = company_id ?? null;
    let senderStaffUserId: string | null = null;
    if (phone) {
      const digits = phone.replace(/\D/g, "");
      const last10 = digits.slice(-10);
      const { data: byPrimary } = await supabaseAdmin
        .from("users")
        .select("id")
        .or(`phone.ilike.%${last10},mobile_number.ilike.%${last10}`)
        .limit(1);
      if (byPrimary?.[0]?.id) senderStaffUserId = byPrimary[0].id;
      if (!senderStaffUserId) {
        const { data: bySecondary } = await supabaseAdmin
          .from("users")
          .select("id")
          .contains("secondary_phones", [`+${digits}`])
          .limit(1);
        if (bySecondary?.[0]?.id) senderStaffUserId = bySecondary[0].id;
      }
    }

    // --- STEP 1: Context-based company resolution (NOT from sender phone) ---
    if (!resolvedCompanyId && candidate_company_name) {
      const { data: matched } = await supabaseAdmin
        .from("companies")
        .select("id")
        .ilike("business_name", `%${candidate_company_name}%`)
        .limit(1);
      if (matched?.[0]) resolvedCompanyId = matched[0].id;
    }

    // Fallback: shadow client by phone
    if (!resolvedCompanyId && phone) {
      if (senderStaffUserId) {
        return new Response(
          JSON.stringify({ error: "Proxy employee order requires explicit client resolution (company_id or candidate_company_name)." }),
          { status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" } },
        );
      }
      const digits = phone.replace(/\D/g, "");
      const last10 = digits.slice(-10);
      const { data: companies } = await supabaseAdmin
        .from("companies")
        .select("id")
        .or(`phone.ilike.%${last10}%,gst_number.ilike.%${last10}%`)
        .limit(1);
      if (companies?.[0]) {
        resolvedCompanyId = companies[0].id;
      } else {
        const { data: newCompany, error: compErr } = await supabaseAdmin
          .from("companies")
          .insert({
            business_name: candidate_company_name || `WhatsApp Lead +${digits}`,
            phone: `+${digits}`,
            gst_number: `WA:${digits}`,
            status: "shadow",
          })
          .select("id")
          .single();
        if (compErr || !newCompany) {
          return new Response(JSON.stringify({ error: "Failed to create shadow client", detail: compErr?.message }), {
            status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
          });
        }
        resolvedCompanyId = newCompany.id;
      }
    }

    if (!resolvedCompanyId) {
      return new Response(JSON.stringify({ error: "Could not resolve company_id" }), {
        status: 400, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    // --- STEP 1b: Three-Step Sender Identification → Sales Exec ---
    let salesExecId: string | null = senderStaffUserId;
    if (phone) {
      const digits = phone.replace(/\D/g, "");
      const last10 = digits.slice(-10);
      // Step A: primary phone match on users
      const { data: byPrimary } = await supabaseAdmin
        .from("users")
        .select("id, role")
        .ilike("phone", `%${last10}%`)
        .limit(1);
      if (byPrimary?.[0]) salesExecId = byPrimary[0].id;
      // Step B: secondary_phones array
      if (!salesExecId) {
        const { data: bySecondary } = await supabaseAdmin
          .from("users")
          .select("id")
          .contains("secondary_phones", [`+${digits}`])
          .limit(1);
        if (bySecondary?.[0]) salesExecId = bySecondary[0].id;
      }
      // Step C: leave null → admin can assign manually
    }

    // --- STEP 2: Activate / update company if requested ---
    if (activate_company) {
      const updatePayload: Record<string, any> = { status: "active" };
      if (company_update) {
        if (company_update.business_name) updatePayload.business_name = company_update.business_name;
        if (company_update.gst_number !== undefined) updatePayload.gst_number = company_update.gst_number || null;
        if (company_update.fssai_number !== undefined) updatePayload.fssai_number = company_update.fssai_number || null;
        if (company_update.registered_address !== undefined) updatePayload.registered_address = company_update.registered_address || null;
      }
      const { error: updateErr } = await supabaseAdmin
        .from("companies")
        .update(updatePayload)
        .eq("id", resolvedCompanyId);
      if (updateErr) {
        return new Response(JSON.stringify({ error: "Company activation failed", detail: updateErr.message }), {
          status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    // --- STEP 3: Build items with catalogue-driven KG conversion ---
    const items: IncomingItem[] = Array.isArray(sku_items) && sku_items.length > 0
      ? sku_items
      : (Array.isArray(sku_names) ? sku_names.map((n: string) => ({ name: n, confidence: 1 })) : []);

    let needsClarification = false;
    let minConfidence = 1;
    const orderItemsPayload: any[] = [];
    let orderTotalKg = 0;

    if (items.length > 0) {
      const names = items.map((i) => i.name);
      const { data: products } = await supabaseAdmin
        .from("products")
        .select("id, name, category, weight_per_box_kg, grams_per_piece")
        .in("name", names);

      const byName = new Map<string, any>();
      (products || []).forEach((p: any) => byName.set(p.name, p));

      for (const it of items) {
        const product = byName.get(it.name);
        if (!product) continue;
        const conf = typeof it.confidence === "number" ? it.confidence : 1;
        if (conf < minConfidence) minConfidence = conf;
        if (conf < CONFIDENCE_THRESHOLD) needsClarification = true;

        const qty = Number(it.quantity) > 0 ? Number(it.quantity) : 1;
        const kg = convertToKg(qty, it.unit, product);
        if (kg && kg > 0) orderTotalKg += kg;

        orderItemsPayload.push({
          product_id: product.id,
          quantity: qty,
          weight_kg: kg,
        });
      }
    }

    // --- STEP 3b: 4-HOUR DUPLICATE CONTENT GUARD ---
    // Same company + same SKU set + same quantities within last 4 hours → flag as potential duplicate.
    let isDuplicate = false;
    let duplicateOfOrderId: string | null = null;
    if (orderItemsPayload.length > 0 && resolvedCompanyId) {
      const fourHoursAgo = new Date(Date.now() - 4 * 3600 * 1000).toISOString();
      const { data: recentOrders } = await supabaseAdmin
        .from("orders")
        .select("id, total_weight_kg, order_items(product_id, quantity)")
        .eq("company_id", resolvedCompanyId)
        .gte("created_at", fourHoursAgo)
        .neq("is_waste", true)
        .limit(20);

      const newSig = orderItemsPayload
        .map((p: any) => `${p.product_id}:${Number(p.quantity)}`)
        .sort()
        .join("|");
      const newKg = Math.round((orderTotalKg || 0) * 100) / 100;

      for (const ro of recentOrders || []) {
        const items = (ro as any).order_items || [];
        if (items.length !== orderItemsPayload.length) continue;
        const oldSig = items
          .map((i: any) => `${i.product_id}:${Number(i.quantity)}`)
          .sort()
          .join("|");
        const oldKg = Math.round(Number((ro as any).total_weight_kg || 0) * 100) / 100;
        // Catalogue-first match: SKU+qty signature equal AND total_weight_kg equal (or both 0)
        if (oldSig === newSig && (oldKg === newKg || (oldKg === 0 && newKg === 0))) {
          isDuplicate = true;
          duplicateOfOrderId = (ro as any).id;
          break;
        }
      }
    }

    // --- STEP 4: Insert order with confidence + clarification + duplicate flags ---
    const orderStatus = isDuplicate
      ? "potential_duplicate"
      : needsClarification ? "awaiting_clarification" : "draft";
    const { data: order, error: orderErr } = await supabaseAdmin
      .from("orders")
      .insert({
        company_id: resolvedCompanyId,
        status: orderStatus,
        dispatch_urgency: "standard",
        tracking_token: generateHexToken(16),
        total_weight_kg: orderTotalKg > 0 ? orderTotalKg : null,
        parser_confidence: minConfidence,
        needs_clarification: needsClarification,
        is_duplicate: isDuplicate,
        duplicate_of_order_id: duplicateOfOrderId,
        wamid: wamid || null,
      })
      .select("id")
      .single();

    if (orderErr || !order) {
      return new Response(JSON.stringify({ error: "Failed to create draft order", detail: orderErr?.message }), {
        status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
      });
    }

    if (orderItemsPayload.length > 0) {
      const itemsToInsert = orderItemsPayload.map((p) => ({ ...p, order_id: order.id }));
      const { error: itemsErr } = await supabaseAdmin.from("order_items").insert(itemsToInsert);
      if (itemsErr) {
        await supabaseAdmin.from("orders").delete().eq("id", order.id);
        return new Response(JSON.stringify({ error: "Failed to insert order items — rolled back", detail: itemsErr.message }), {
          status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
        });
      }
    }

    // --- STEP 5: Mark webhooks as processed ---
    const allWebhookIds = [
      ...(webhook_id ? [webhook_id] : []),
      ...(Array.isArray(webhook_ids) ? webhook_ids : []),
    ];
    if (allWebhookIds.length > 0) {
      await supabaseAdmin
        .from("debug_webhooks")
        .update({ processed: true })
        .in("id", allWebhookIds);
    }

    // --- STEP 6: Protected WA-100 notification quarantine ---
    // Draft creation is complete; do not infer recipient consent or send via
    // service_role just because a request supplies an arbitrary phone/message.
    // Core-owned durable dispatch/outbound authority must be commissioned
    // separately before any WhatsApp dispatch is reintroduced.
    const whatsappNotificationStatus =
      send_whatsapp_to || whatsapp_message
        ? "NOT_SENT_RELEASE_GATED"
        : "NOT_REQUESTED";

    return new Response(JSON.stringify({
      ok: true,
      order_id: order.id,
      company_id: resolvedCompanyId,
      sales_exec_id: salesExecId,
      total_weight_kg: orderTotalKg,
      parser_confidence: minConfidence,
      needs_clarification: needsClarification,
      is_duplicate: isDuplicate,
      duplicate_of_order_id: duplicateOfOrderId,
      status: orderStatus,
      whatsapp_notification_status: whatsappNotificationStatus,
    }), {
      status: 200, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  } catch (e) {
    const msg = e instanceof Error ? e.message : "Unexpected error";
    return new Response(JSON.stringify({ error: msg }), {
      status: 500, headers: { ...corsHeaders, "Content-Type": "application/json" },
    });
  }
});
