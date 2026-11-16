import { createClient } from "npm:@supabase/supabase-js@2.45.0";

export type InternalCaller = {
  kind: "service_role" | "staff";
  userId: string | null;
};

export type InternalAuthorizationResult =
  | { ok: true; caller: InternalCaller }
  | { ok: false; status: 401 | 403 | 500; error: string };

function resolvePublicKey(): string | null {
  return (
    Deno.env.get("SUPABASE_ANON_KEY") ??
      Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ??
      null
  );
}

/**
 * Compare bearer credentials without a prefix-dependent string equality check.
 * SHA-256 yields fixed-size byte arrays; inspect every byte without early exit.
 * Never log either credential or its digest.
 */
export async function matchesServiceRoleToken(
  candidate: string,
  secret: string,
): Promise<boolean> {
  const encoder = new TextEncoder();
  const [candidateDigest, secretDigest] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(candidate)),
    crypto.subtle.digest("SHA-256", encoder.encode(secret)),
  ]);

  const actual = new Uint8Array(candidateDigest);
  const expected = new Uint8Array(secretDigest);
  let mismatch = 0;
  for (let i = 0; i < actual.length; i++) {
    mismatch |= actual[i] ^ expected[i];
  }
  return mismatch === 0;
}

/**
 * Authorizes either an internal service-role invocation or an authenticated
 * Oasis staff user. Never trusts a caller-supplied user/operator id.
 */
export async function requireInternalStaff(
  req: Request,
): Promise<InternalAuthorizationResult> {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = resolvePublicKey();

  if (!supabaseUrl || !serviceRoleKey || !publicKey) {
    return {
      ok: false,
      status: 500,
      error: "Authentication is not configured",
    };
  }

  const authorization = req.headers.get("Authorization") ?? "";
  if (!authorization.startsWith("Bearer ")) {
    return { ok: false, status: 401, error: "Unauthorized" };
  }

  const token = authorization.slice(7).trim();
  if (!token) {
    return { ok: false, status: 401, error: "Unauthorized" };
  }

  if (await matchesServiceRoleToken(token, serviceRoleKey)) {
    return {
      ok: true,
      caller: { kind: "service_role", userId: null },
    };
  }

  const authClient = createClient(supabaseUrl, publicKey, {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${token}` } },
  });

  const { data: userData, error: userError } = await authClient.auth.getUser(
    token,
  );
  if (userError || !userData.user?.id) {
    return { ok: false, status: 401, error: "Unauthorized" };
  }

  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false },
  });
  const { data: isStaff, error: staffError } = await admin.rpc(
    "is_internal_staff",
    { _user_id: userData.user.id },
  );

  if (staffError) {
    console.error(
      "[requireInternalStaff] staff lookup failed:",
      staffError.message,
    );
    return { ok: false, status: 500, error: "Unable to verify staff access" };
  }

  if (isStaff !== true) {
    return { ok: false, status: 403, error: "Forbidden" };
  }

  return {
    ok: true,
    caller: { kind: "staff", userId: userData.user.id },
  };
}
