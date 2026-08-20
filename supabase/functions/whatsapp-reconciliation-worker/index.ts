import { createClient } from "npm:@supabase/supabase-js@2.95.0";

const headers = { "Content-Type": "application/json" };
const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers });

function hourKey(date: Date): string {
  return date.toISOString().slice(0, 13).replace(/[-T:]/g, "");
}

Deno.serve(async (req: Request) => {
  if (req.method !== "POST") return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authorization = req.headers.get("Authorization") ?? "";
  if (!supabaseUrl || !serviceRoleKey) return respond({ success: false, error: "WORKER_NOT_CONFIGURED" }, 503);
  if (authorization !== `Bearer ${serviceRoleKey}`) {
    return respond({ success: false, error: "TRUSTED_PROCESSOR_REQUIRED" }, 401);
  }

  let requestedWindowMinutes = 60;
  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    if (body.window_minutes !== undefined) {
      const parsed = Number(body.window_minutes);
      if (!Number.isInteger(parsed) || parsed < 5 || parsed > 1440) {
        return respond({ success: false, error: "WINDOW_MINUTES_OUT_OF_RANGE" }, 400);
      }
      requestedWindowMinutes = parsed;
    }
  } catch {
    return respond({ success: false, error: "INVALID_REQUEST" }, 400);
  }

  const end = new Date();
  const start = new Date(end.getTime() - requestedWindowMinutes * 60_000);
  const due = new Date(end.getTime() + 4 * 60 * 60_000);
  const key = `hour-${hourKey(end)}-window-${requestedWindowMinutes}`;
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await admin.rpc("whatsapp_run_system_reconciliation", {
    p_window_start: start.toISOString(),
    p_window_end: end.toISOString(),
    p_shift_code: "SYSTEM_ROLLING",
    p_exception_due_at: due.toISOString(),
    p_idempotency_key: key,
  });
  if (error) {
    console.error("[whatsapp-reconciliation-worker] reconciliation failed", error.code ?? "RPC_ERROR");
    return respond({ success: false, error: "RECONCILIATION_FAILED" }, 502);
  }

  return respond({ success: true, reconciliation: data, human_signoff_required: true });
});
