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

export function bearerToken(req: Request): string | null {
  const value = req.headers.get("Authorization") ?? "";
  if (!value.startsWith("Bearer ")) return null;
  const token = value.slice(7).trim();
  return token || null;
}

export type FinancialLedgerAuthorityDeps = {
  verifyCronSecret: (
    candidate: string,
  ) => Promise<{ data: boolean | null; error: { message: string } | null }>;
  getUserIdFromToken: (
    token: string,
  ) => Promise<{ userId: string | null; invalid: boolean }>;
  isFinancialOperator: (
    userId: string,
  ) => Promise<{ allowed: boolean | null; error: { message: string } | null }>;
};

export async function resolveFinancialLedgerAuthority(
  req: Request,
  deps: FinancialLedgerAuthorityDeps,
  options: { publicKeyAvailable: boolean },
): Promise<LedgerAuthority> {
  const cronCandidate = req.headers.get("x-oasis-cron-secret")?.trim() ?? "";
  if (cronCandidate) {
    const { data, error } = await deps.verifyCronSecret(cronCandidate);
    if (error) {
      console.error(
        "[financial-ledger] cron authority lookup failed",
        error.message,
      );
      return { ok: false, status: 500, error: "authority_unavailable" };
    }
    return data === true
      ? { ok: true, kind: "cron", userId: null }
      : { ok: false, status: 403, error: "forbidden" };
  }

  const token = bearerToken(req);
  if (!token) return { ok: false, status: 401, error: "unauthorized" };
  if (!options.publicKeyAvailable) {
    console.error("[financial-ledger] public auth key unavailable");
    return { ok: false, status: 500, error: "authority_unavailable" };
  }

  const { userId, invalid } = await deps.getUserIdFromToken(token);
  if (invalid || !userId) {
    return { ok: false, status: 401, error: "unauthorized" };
  }

  const { allowed, error: roleError } = await deps.isFinancialOperator(userId);
  if (roleError) {
    console.error(
      "[financial-ledger] finance role lookup failed",
      roleError.message,
    );
    return { ok: false, status: 500, error: "authority_unavailable" };
  }
  if (allowed !== true) return { ok: false, status: 403, error: "forbidden" };

  return { ok: true, kind: "user", userId };
}

export async function requireFinancialLedgerAuthority(
  req: Request,
  supabaseUrl: string,
  serviceRoleKey: string,
  publicKey: string,
): Promise<LedgerAuthority> {
  const admin = createAdminClient(supabaseUrl, serviceRoleKey);

  return await resolveFinancialLedgerAuthority(
    req,
    {
      verifyCronSecret: async (candidate) => {
        const { data, error } = await admin.rpc(
          "verify_financial_ledger_cron_secret",
          { _candidate: candidate },
        );
        return { data, error };
      },
      getUserIdFromToken: async (token) => {
        const authClient = createClient(supabaseUrl, publicKey, {
          auth: { persistSession: false },
          global: { headers: { Authorization: `Bearer ${token}` } },
        });
        const { data: userData, error: userError } = await authClient.auth
          .getUser(token);
        const userId = userData.user?.id ?? null;
        return { userId, invalid: Boolean(userError || !userId) };
      },
      isFinancialOperator: async (userId) => {
        const { data, error } = await admin.rpc(
          "is_financial_ledger_operator",
          { _user_id: userId },
        );
        return { allowed: data, error };
      },
    },
    { publicKeyAvailable: Boolean(publicKey) },
  );
}
