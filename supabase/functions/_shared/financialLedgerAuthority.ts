import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.45.0";

export type LedgerAuthority =
  | { ok: true; kind: "cron" | "user"; userId: string | null }
  | { ok: false; status: 401 | 403 | 500; error: string };

type AdminClient = SupabaseClient;

export function createAdminClient(
  supabaseUrl: string,
  serviceRoleKey: string,
): SupabaseClient {
  return createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });
}

export function jsonHeaders(): Record<string, string> {
  return {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Pragma": "no-cache",
    "X-Content-Type-Options": "nosniff",
  };
}

export function corsHeaders(): Record<string, string> {
  return {
    ...jsonHeaders(),
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers":
      "authorization, x-client-info, apikey, content-type, x-oasis-cron-secret",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
  };
}

export function jsonResponse(
  body: Record<string, unknown>,
  status = 200,
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: corsHeaders(),
  });
}

function bearerToken(req: Request): string | null {
  const value = req.headers.get("Authorization") ?? "";
  if (!value.startsWith("Bearer ")) return null;
  const token = value.slice(7).trim();
  return token || null;
}

async function verifyCronSecret(
  req: Request,
  admin: AdminClient,
): Promise<LedgerAuthority | null> {
  const candidate = req.headers.get("x-oasis-cron-secret")?.trim() ?? "";
  if (!candidate) return null;

  const { data, error } = await admin.rpc(
    "verify_financial_ledger_cron_secret",
    { _candidate: candidate },
  );
  if (error) {
    console.error("[financial-ledger] cron authority lookup failed", error.message);
    return { ok: false, status: 500, error: "authority_unavailable" };
  }
  return data === true
    ? { ok: true, kind: "cron", userId: null }
    : { ok: false, status: 403, error: "forbidden" };
}

export async function requireFinancialLedgerAuthority(
  req: Request,
  supabaseUrl: string,
  serviceRoleKey: string,
  publicKey: string,
): Promise<LedgerAuthority> {
  const admin = createAdminClient(supabaseUrl, serviceRoleKey);

  const cronResult = await verifyCronSecret(req, admin);
  if (cronResult) return cronResult;

  const token = bearerToken(req);
  if (!token) return { ok: false, status: 401, error: "unauthorized" };
  if (!publicKey) {
    console.error("[financial-ledger] public auth key unavailable");
    return { ok: false, status: 500, error: "authority_unavailable" };
  }

  const authClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });
  const { data: userData, error: userError } = await authClient.auth.getUser(token);
  const userId = userData.user?.id ?? null;
  if (userError || !userId) {
    return { ok: false, status: 401, error: "unauthorized" };
  }

  const { data: allowed, error: roleError } = await admin.rpc(
    "is_financial_ledger_operator",
    { _user_id: userId },
  );
  if (roleError) {
    console.error("[financial-ledger] finance role lookup failed", roleError.message);
    return { ok: false, status: 500, error: "authority_unavailable" };
  }
  if (allowed !== true) return { ok: false, status: 403, error: "forbidden" };

  return { ok: true, kind: "user", userId };
}
