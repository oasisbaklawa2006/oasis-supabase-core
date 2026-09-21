import { createClient } from "npm:@supabase/supabase-js@2.95.0";

function json(body: unknown, status: number) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "Content-Type": "application/json",
      "Cache-Control": "no-store",
      "X-Content-Type-Options": "nosniff",
    },
  });
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function randomToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return "odt_" + Array.from(bytes)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

Deno.serve(async (req) => {
  if (req.method !== "GET") return json({ ok: false, error: "method_not_allowed" }, 405);

  const url = new URL(req.url);
  const match = url.pathname.match(/\/v1\/devices\/(tv-[0-9a-fA-F-]{36})\/assignment\/?$/);
  if (!match) return json({ ok: false, error: "route_not_found" }, 404);
  const deviceId = match[1];

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!supabaseUrl || !serviceKey) return json({ ok: false, error: "server_not_configured" }, 503);

  const sb = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const { data: row, error } = await sb
    .from("display_device_registry_v1")
    .select("device_id,enrollment_code_hash,display_token_hash,surface_key,friendly_name,location,config_version,is_active,assigned_at")
    .eq("device_id", deviceId)
    .maybeSingle();

  if (error) return json({ ok: false, error: "registry_unavailable" }, 503);
  if (!row) return json({ ok: false, error: "pending_enrollment" }, 404);
  if (!row.is_active) return json({ ok: false, error: "device_revoked" }, 403);

  const authHeader = req.headers.get("Authorization")?.trim() ?? "";
  const bearer = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  const enrollment = req.headers.get("X-Oasis-Enrollment-Code")?.trim().toUpperCase() ?? "";
  let issuedToken: string | null = null;

  if (bearer) {
    if (!row.display_token_hash || await sha256(bearer) !== row.display_token_hash) {
      return json({ ok: false, error: "device_token_invalid" }, 401);
    }
  } else {
    if (!enrollment || await sha256(enrollment) !== row.enrollment_code_hash) {
      return json({ ok: false, error: "enrollment_code_invalid" }, 401);
    }
    issuedToken = randomToken();
    const { error: tokenError } = await sb
      .from("display_device_registry_v1")
      .update({
        display_token_hash: await sha256(issuedToken),
        last_seen_at: new Date().toISOString(),
        apk_version: req.headers.get("X-Oasis-Apk-Version")?.slice(0, 64) ?? null,
        updated_at: new Date().toISOString(),
      })
      .eq("device_id", deviceId)
      .eq("is_active", true);
    if (tokenError) return json({ ok: false, error: "token_issue_failed" }, 503);
  }

  if (!issuedToken) {
    await sb
      .from("display_device_registry_v1")
      .update({
        last_seen_at: new Date().toISOString(),
        apk_version: req.headers.get("X-Oasis-Apk-Version")?.slice(0, 64) ?? null,
        updated_at: new Date().toISOString(),
      })
      .eq("device_id", deviceId)
      .eq("is_active", true);
  }

  return json({
    v: 1,
    surfaceKey: row.surface_key,
    friendlyName: row.friendly_name,
    location: row.location,
    configVersion: Number(row.config_version),
    assignedAtEpochMs: Date.parse(row.assigned_at),
    ...(issuedToken ? { deviceToken: issuedToken } : {}),
  }, 200);
});
