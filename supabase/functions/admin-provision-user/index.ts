// Governed server-side staff/QA account provisioning.
//
// Central issue #368, Lane 1 security closure. This is the only path
// permitted to call the Supabase Auth Admin API to create/invite an
// internal-staff or QA identity, and the only caller of the SQL RPCs
// in 20260819110000_staff_provisioning_authority.sql that actually write
// public.users.role / public.user_role_map (grant_staff_role, service_role
// only). The browser never holds a service-role credential and never
// reaches those RPCs directly.
//
// Two modes:
//   - "invite" (default; real staff): Supabase's own secure invite-link
//     email via auth.admin.inviteUserByEmail(). No password is ever
//     generated or handled by this function.
//   - "service_credential" (permanent CI/QA identities only): a strong
//     random password is generated here, the identity is created with it,
//     and the password is returned ONCE in the response body -- never
//     emailed, logged, or persisted anywhere. The caller (a human with
//     admin authority, operating docs/LANE1_QA_ACCOUNT_MATRIX.md's
//     provisioning flow) is responsible for putting it straight into a
//     GitHub Actions secret and never storing it elsewhere.
//
// PRODUCTION RUNTIME CERTIFICATION PENDING: this function has not been
// deployed or exercised against a live Supabase Auth Admin API from this
// change. It follows the documented Admin API contract and this repo's
// existing Edge Function conventions (see catalogue-ai-copy), but real
// deployment + an authenticated dry run is Procedure 8, gated on owner
// authorization -- see docs/security/EDGE_FUNCTION_RUNTIME_CERTIFICATION_2026-07-31.md.

import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  allowedOrigin as isAllowedOrigin,
  decodeJwtAal,
  generateStrongPassword,
  parseRequest,
  type ProvisionRequest,
} from "../_shared/adminProvisionUser.ts";

function json(body: unknown, status: number, origin: string | null) {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  };
  if (origin) headers["Access-Control-Allow-Origin"] = origin;
  return new Response(JSON.stringify(body), { status, headers });
}

function allowedOrigin(req: Request): string | null {
  return isAllowedOrigin(Deno.env.get("ADMIN_PROVISION_ALLOWED_ORIGIN"), req.headers.get("Origin"));
}

function resolveSupabasePublicKey(): string | undefined {
  const publishableKeys = Deno.env.get("SUPABASE_PUBLISHABLE_KEYS");
  if (publishableKeys) {
    try {
      const keyNames = JSON.parse(publishableKeys) as Record<string, unknown>;
      const defaultKeyName = keyNames.default;
      if (typeof defaultKeyName === "string") {
        const value = Deno.env.get(defaultKeyName);
        if (value) return value;
      }
    } catch {
      // fall through to the legacy env var below
    }
  }
  return Deno.env.get("SUPABASE_ANON_KEY");
}

// Best-effort existing-identity lookup, bounded so a pathological auth.users
// size cannot turn this into an unbounded scan. Supabase's Admin API has no
// documented "get user by email" call in this SDK version, so this paginates
// listUsers() and matches client-side -- adequate for occasional staff/QA
// provisioning, not a high-throughput path.
async function findExistingUserByEmail(
  admin: ReturnType<typeof createClient>["auth"]["admin"],
  email: string,
): Promise<{ id: string } | null> {
  const target = email.toLowerCase();
  for (let page = 1; page <= 5; page++) {
    const { data, error } = await admin.listUsers({ page, perPage: 200 });
    if (error || !data?.users) break;
    const match = data.users.find((u) => u.email?.toLowerCase() === target);
    if (match) return { id: match.id };
    if (data.users.length < 200) break; // last page
  }
  return null;
}

Deno.serve(async (req) => {
  const origin = allowedOrigin(req);
  if (req.method === "OPTIONS") {
    if (!origin) return json({ ok: false, error: "origin not allowed" }, 403, null);
    return new Response(null, {
      status: 204,
      headers: {
        "Access-Control-Allow-Origin": origin,
        "Access-Control-Allow-Headers": "authorization, content-type, x-client-info, apikey",
        "Access-Control-Allow-Methods": "POST, OPTIONS",
        "Access-Control-Max-Age": "600",
        "Vary": "Origin",
      },
    });
  }
  if (req.method !== "POST") return json({ ok: false, error: "method not allowed" }, 405, origin);
  if (!origin) return json({ ok: false, error: "origin not allowed" }, 403, null);

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = resolveSupabasePublicKey();
  if (!supabaseUrl || !serviceRoleKey || !publicKey) {
    return json({ ok: false, error: "provisioning service is not configured" }, 503, origin);
  }

  // Resolve the caller from their own bearer token via the public (anon)
  // key -- this never uses the service-role key to authenticate the
  // caller, only to act afterward once authority is confirmed.
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return json({ ok: false, error: "unauthorized" }, 401, origin);
  }
  const callerClient = createClient(supabaseUrl, publicKey, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: callerData, error: callerError } = await callerClient.auth.getUser(
    authorization.slice(7),
  );
  if (callerError || !callerData.user?.id) {
    return json({ ok: false, error: "unauthorized" }, 401, origin);
  }
  const actorId = callerData.user.id;

  // AAL2 (step-up) requirement for privileged roles: staff_provisionable_roles
  // marks which roles need it, but the RPC layer -- SECURITY DEFINER, called
  // here with the service-role client -- cannot see the caller's session AAL
  // once invoked that way, so this function reads it directly off the
  // caller's own bearer JWT, the same claim public.has_step_up_auth() checks
  // (auth.jwt() ->> 'aal'). getUser() above already verified this token's
  // signature, so decoding its payload here is on the same trust boundary.
  const aal = decodeJwtAal(authorization.slice(7));

  let input: ProvisionRequest;
  try {
    input = parseRequest(await req.json());
  } catch (error) {
    return json(
      { ok: false, error: error instanceof Error ? error.message : "invalid request" },
      400,
      origin,
    );
  }

  const admin = createClient(supabaseUrl, serviceRoleKey);

  // Pre-flight authority + allowlist check, before any Auth Admin API call
  // -- an unauthorized or role-escalation request never gets as far as
  // creating an auth identity. can_grant_staff_role is granted to
  // service_role only, so this is the only client that can call it.
  const { data: canGrant, error: canGrantError } = await admin.rpc("can_grant_staff_role", {
    p_actor: actorId,
    p_role_key: input.roleKey,
  });
  if (canGrantError || canGrant !== true) {
    return json({ ok: false, error: "not authorised to grant this role" }, 403, origin);
  }

  // Look up whether requires_step_up applies to this role, then enforce
  // AAL2 on the caller for exactly those roles.
  const { data: roleRow } = await admin
    .from("staff_provisionable_roles")
    .select("requires_step_up")
    .eq("role_key", input.roleKey.toLowerCase())
    .maybeSingle();
  if (roleRow?.requires_step_up && aal !== "aal2") {
    return json(
      { ok: false, error: "this role requires a step-up (AAL2) session on the granting admin" },
      403,
      origin,
    );
  }

  try {
    const existing = await findExistingUserByEmail(admin.auth.admin, input.email);
    let authUserId: string;
    let generatedPassword: string | null = null;

    if (existing) {
      // Idempotent path: reuse the existing identity, never create a
      // duplicate. grant_staff_role below is itself idempotent too.
      authUserId = existing.id;
    } else if (input.mode === "service_credential") {
      generatedPassword = generateStrongPassword();
      const { data: created, error: createError } = await admin.auth.admin.createUser({
        email: input.email,
        password: generatedPassword,
        email_confirm: true,
        user_metadata: { full_name: input.displayName ?? null, provisioned_via: "admin-provision-user" },
      });
      if (createError || !created.user?.id) {
        return json(
          { ok: false, error: createError?.message ?? "failed to create identity" },
          502,
          origin,
        );
      }
      authUserId = created.user.id;
    } else {
      const { data: invited, error: inviteError } = await admin.auth.admin.inviteUserByEmail(
        input.email,
        { data: { full_name: input.displayName ?? null } },
      );
      if (inviteError || !invited.user?.id) {
        return json(
          { ok: false, error: inviteError?.message ?? "failed to invite identity" },
          502,
          origin,
        );
      }
      authUserId = invited.user.id;
    }

    // The only write of public.users.role / public.user_role_map. If this
    // fails after the identity above was just created, the caller can
    // safely retry the whole request -- findExistingUserByEmail will now
    // find the identity and this step alone will run, since grant_staff_role
    // is itself idempotent on repeat grants.
    const { data: granted, error: grantError } = await admin.rpc("grant_staff_role", {
      p_auth_user_id: authUserId,
      p_email: input.email,
      p_display_name: input.displayName ?? null,
      p_role_key: input.roleKey,
      p_actor: actorId,
      p_department: input.department ?? null,
      p_designation: input.designation ?? null,
    });
    if (grantError) {
      return json({ ok: false, error: grantError.message }, 502, origin);
    }

    return json(
      {
        ok: true,
        user: granted,
        // Present only for mode=service_credential and only on this one
        // response -- never logged, emailed, or persisted by this function.
        generatedPassword,
      },
      200,
      origin,
    );
  } catch (error) {
    return json(
      { ok: false, error: error instanceof Error ? error.message : "provisioning failed" },
      500,
      origin,
    );
  }
});
