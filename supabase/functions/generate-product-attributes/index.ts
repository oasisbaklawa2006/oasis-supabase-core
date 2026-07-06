import { corsHeaders } from "npm:@supabase/supabase-js@2.95.0/cors";

const DISCLAIMER =
  "AI suggestion only. Final GST/HSN must be approved manually by authorized user.";

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  if (req.method !== "POST") {
    return json({ ok: false, message: "Method not allowed" }, 405);
  }

  try {
    const body = await req.json().catch(() => ({}));
    const product_name = String(body?.product_name ?? "").trim();
    const category = String(body?.category ?? "").trim();
    const name = product_name.toLowerCase();
    const isConfectionery = /chocolate|sweet|dragee|baklawa|confection/i.test(name);

    const suggestions = {
      hsn_code: isConfectionery ? "18069090" : "21069099",
      gst_rate: isConfectionery ? "5" : "12",
      shelf_life_days: "180",
      ingredients: "AI draft — verify against recipe sheet.",
      allergen_warnings: "May contain nuts, gluten, dairy — verify.",
      nutritional_info: "Per 100g — values require lab verification.",
      storage_instructions: "Store in a cool, dry place away from direct sunlight.",
      category_hint: category || null,
    };

    return json({
      suggestion_only: true,
      approved: false,
      disclaimer: DISCLAIMER,
      suggestions,
    });
  } catch (e) {
    const message = e instanceof Error ? e.message : "Unknown error";
    return json({ ok: false, message }, 500);
  }
});

function json(payload: unknown, status = 200) {
  return new Response(JSON.stringify(payload), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
