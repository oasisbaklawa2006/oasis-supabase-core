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

async function sha256Token(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

type Assignment = {
  v: number;
  surfaceKey: string;
  friendlyName: string | null;
  location: string | null;
  configVersion: number;
  assignedAtEpochMs: number;
};

type AssignmentResult = {
  status?: string;
  authMode?: "token" | "enrollment";
  assignment?: Assignment;
};

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

  const authHeader = req.headers.get("Authorization")?.trim() ?? "";
  const bearer = authHeader.startsWith("Bearer ") ? authHeader.slice(7).trim() : "";
  const enrollment = req.headers.get("X-Oasis-Enrollment-Code")?.trim().toUpperCase() ?? "";
  const issuedToken = bearer ? null : randomToken();
  const expectedAuthMode = bearer ? "token" : "enrollment";
  const { data, error } = await sb.rpc("display_device_assignment_v1", {
    p_device_id: deviceId,
    p_enrollment_code: bearer ? null : enrollment,
    p_display_token_hash: bearer ? await sha256Token(bearer) : null,
    p_new_display_token_hash: issuedToken ? await sha256Token(issuedToken) : null,
    p_apk_version: req.headers.get("X-Oasis-Apk-Version")?.slice(0, 64) ?? null,
  });

  if (error || !data || typeof data !== "object") {
    const serviceError = bearer ? "registry_unavailable" : "token_issue_failed";
    return json({ ok: false, error: serviceError }, 503);
  }

  const result = data as AssignmentResult;
  if (result.status === "pending_enrollment") {
    return json({ ok: false, error: "pending_enrollment" }, 404);
  }
  if (result.status === "device_revoked") {
    return json({ ok: false, error: "device_revoked" }, 403);
  }
  if (result.status === "device_token_invalid") {
    return json({ ok: false, error: "device_token_invalid" }, 401);
  }
  if (result.status === "enrollment_code_invalid") {
    return json({ ok: false, error: "enrollment_code_invalid" }, 401);
  }
  if (result.status !== "ok" || result.authMode !== expectedAuthMode || !result.assignment) {
    const serviceError = bearer ? "registry_unavailable" : "token_issue_failed";
    return json({ ok: false, error: serviceError }, 503);
  }

  return json({
    ...result.assignment,
    ...(issuedToken ? { deviceToken: issuedToken } : {}),
  }, 200);
});
