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

import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import {
  allowedOrigin as isAllowedOrigin,
  decodeJwtAal,
  stepUpBlocksGrant,
  findExistingUserAcrossPages,
  generateStrongPassword,
  parseRequest,
  type ProvisionRequest,
} from "../_shared/adminProvisionUser.ts";

type AdminClient = SupabaseClient;

const jsonResponse = (
  body: unknown,
  status: number,
  origin: string | null,
): Response => {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
    "Cache-Control": "no-store",
    "Vary": "Origin",
  };
  if (origin) headers["Access-Control-Allow-Origin"] = origin;
  return new Response(JSON.stringify(body), { status, headers });
};

const resolveOrigin = (req: Request): string | null => {
  return isAllowedOrigin(
    Deno.env.get("ADMIN_PROVISION_ALLOWED_ORIGIN"),
    req.headers.get("Origin"),
  );
};

const corsPreflightResponse = (origin: string): Response =>
  new Response(null, {
    status: 204,
    headers: {
      "Access-Control-Allow-Origin": origin,
      "Access-Control-Allow-Headers":
        "authorization, content-type, x-client-info, apikey",
      "Access-Control-Allow-Methods": "POST, OPTIONS",
      "Access-Control-Max-Age": "600",
      "Vary": "Origin",
    },
  });

const resolveSupabasePublicKey = (): string | undefined => {
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
};

type EnvConfig = {
  supabaseUrl: string;
  serviceRoleKey: string;
  publicKey: string;
};

const readEnvConfig = (): EnvConfig | null => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const publicKey = resolveSupabasePublicKey();
  if (!supabaseUrl || !serviceRoleKey || !publicKey) return null;
  return { supabaseUrl, serviceRoleKey, publicKey };
};

// Resolves the caller from their own bearer token via the public (anon) key
// -- this never uses the service-role key to authenticate the caller, only
// to act afterward once authority is confirmed. Also decodes the caller's
// own JWT for its "aal" claim, the same one public.has_step_up_auth() reads
// (auth.jwt() ->> 'aal') -- getUser() below already verified this token's
// signature, so decoding its payload here is on the same trust boundary.
const resolveCaller = async (
  req: Request,
  env: EnvConfig,
): Promise<{ actorId: string; aal: string | undefined } | null> => {
  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return null;
  const token = authorization.slice(7);
  const callerClient = createClient(env.supabaseUrl, env.publicKey, {
    global: { headers: { Authorization: authorization } },
  });
  const { data: callerData, error: callerError } = await callerClient.auth
    .getUser(token);
  if (callerError || !callerData.user?.id) return null;
  return { actorId: callerData.user.id, aal: decodeJwtAal(token) };
};

const canGrantRole = async (
  admin: AdminClient,
  actorId: string,
  roleKey: string,
): Promise<boolean> => {
  const { data: canGrant, error } = await admin.rpc("can_grant_staff_role", {
    p_actor: actorId,
    p_role_key: roleKey,
  });
  return !error && canGrant === true;
};

const roleRequiresStepUp = async (
  admin: AdminClient,
  roleKey: string,
): Promise<boolean> => {
  const { data: roleRow, error } = await admin
    .from("staff_provisionable_roles")
    .select("requires_step_up")
    .eq("role_key", roleKey.toLowerCase())
    .maybeSingle();
  // Fail closed: an unreadable or missing allowlist row must not disable
  // step-up for a role that can_grant_staff_role has already approved.
  if (error || !roleRow) return true;
  return roleRow.requires_step_up === true;
};

// Pre-flight authority + allowlist check, before any Auth Admin API call --
// an unauthorized or role-escalation request never gets as far as creating
// an auth identity. can_grant_staff_role is granted to service_role only,
// so this is the only client that can call it. Roles marked
// requires_step_up additionally need the caller's own session to be AAL2.
const authorizeGrant = async (
  admin: AdminClient,
  actorId: string,
  roleKey: string,
  aal: string | undefined,
): Promise<string | null> => {
  if (!(await canGrantRole(admin, actorId, roleKey))) {
    return "not authorised to grant this role";
  }
  const stepUpError = stepUpBlocksGrant(await roleRequiresStepUp(admin, roleKey), aal);
  if (stepUpError) return stepUpError;
  return null;
};

// Supabase Auth Admin currently exposes listUsers(page, perPage), not a
// documented get-by-email call. Exhaust the paginated list rather than
// imposing the former five-page/1,000-user ceiling; the shared scanner is
// unit-tested without importing this Deno.serve module. Any listUsers error
// is propagated so identity creation never proceeds after an uncertain read.
const findExistingUserByEmail = (
  admin: AdminClient,
  email: string,
): Promise<{ id: string } | null> =>
  findExistingUserAcrossPages(
    email,
    async (page, perPage) => {
      const { data, error } = await admin.auth.admin.listUsers({
        page,
        perPage,
      });
      if (error || !data?.users) {
        throw new Error(
          `unable to verify existing identity: ${
            error?.message ?? "listUsers returned no data"
          }`,
        );
      }
      return {
        users: data.users,
        total: "total" in data && typeof data.total === "number"
          ? data.total
          : undefined,
      };
    },
  );

type ResolvedIdentity = {
  authUserId: string;
  generatedPassword: string | null;
};
type IdentityOutcome = { ok: true; identity: ResolvedIdentity } | {
  ok: false;
  error: string;
};

const createServiceCredentialIdentity = async (
  admin: AdminClient,
  input: ProvisionRequest,
): Promise<IdentityOutcome> => {
  const generatedPassword = generateStrongPassword();
  const { data: created, error: createError } = await admin.auth.admin
    .createUser({
      email: input.email,
      password: generatedPassword,
      email_confirm: true,
      user_metadata: {
        full_name: input.displayName ?? null,
        provisioned_via: "admin-provision-user",
      },
    });
  if (createError || !created.user?.id) {
    return {
      ok: false,
      error: createError?.message ?? "failed to create identity",
    };
  }
  return {
    ok: true,
    identity: { authUserId: created.user.id, generatedPassword },
  };
};

const createInviteIdentity = async (
  admin: AdminClient,
  input: ProvisionRequest,
): Promise<IdentityOutcome> => {
  const { data: invited, error: inviteError } = await admin.auth.admin
    .inviteUserByEmail(
      input.email,
      { data: { full_name: input.displayName ?? null } },
    );
  if (inviteError || !invited.user?.id) {
    return {
      ok: false,
      error: inviteError?.message ?? "failed to invite identity",
    };
  }
  return {
    ok: true,
    identity: { authUserId: invited.user.id, generatedPassword: null },
  };
};

// Idempotent: an existing identity (matched by email) is always reused
// rather than duplicated. grant_staff_role (called by the handler after
// this resolves) is itself idempotent too, so a retry after a partial
// failure here safely converges rather than duplicating anything.
const resolveIdentity = async (
  admin: AdminClient,
  input: ProvisionRequest,
): Promise<IdentityOutcome> => {
  const existing = await findExistingUserByEmail(admin, input.email);
  if (existing) {
    return {
      ok: true,
      identity: { authUserId: existing.id, generatedPassword: null },
    };
  }
  return input.mode === "service_credential"
    ? createServiceCredentialIdentity(admin, input)
    : createInviteIdentity(admin, input);
};

// The only write of public.users.role / public.user_role_map.
const grantRole = (
  admin: AdminClient,
  input: ProvisionRequest,
  authUserId: string,
  actorId: string,
) =>
  admin.rpc("grant_staff_role", {
    p_auth_user_id: authUserId,
    p_email: input.email,
    p_display_name: input.displayName ?? null,
    p_role_key: input.roleKey,
    p_actor: actorId,
    p_department: input.department ?? null,
    p_designation: input.designation ?? null,
  });

type AuthorizedContext = {
  admin: AdminClient;
  input: ProvisionRequest;
  actorId: string;
};
type ContextOutcome = { ok: true; context: AuthorizedContext } | {
  ok: false;
  response: Response;
};

// Authenticates the caller, parses the request, and checks grant authority --
// everything that must succeed before any Auth Admin API call is made.
const buildAuthorizedContext = async (
  req: Request,
  origin: string | null,
  env: EnvConfig,
): Promise<ContextOutcome> => {
  const caller = await resolveCaller(req, env);
  if (!caller) {
    return {
      ok: false,
      response: jsonResponse({ ok: false, error: "unauthorized" }, 401, origin),
    };
  }
  const { actorId, aal } = caller;

  let input: ProvisionRequest;
  try {
    input = parseRequest(await req.json());
  } catch (error) {
    const message = error instanceof Error ? error.message : "invalid request";
    return {
      ok: false,
      response: jsonResponse({ ok: false, error: message }, 400, origin),
    };
  }

  const admin = createClient(env.supabaseUrl, env.serviceRoleKey);
  const authorizationError = await authorizeGrant(
    admin,
    actorId,
    input.roleKey,
    aal,
  );
  if (authorizationError) {
    return {
      ok: false,
      response: jsonResponse(
        { ok: false, error: authorizationError },
        403,
        origin,
      ),
    };
  }
  return { ok: true, context: { admin, input, actorId } };
};

// Resolves (or creates) the identity and grants the role -- the only part of
// the request that touches the Auth Admin API and the RPC layer.
const performProvisioning = async (
  context: AuthorizedContext,
  origin: string | null,
): Promise<Response> => {
  const { admin, input, actorId } = context;
  try {
    const identityOutcome = await resolveIdentity(admin, input);
    if (!identityOutcome.ok) {
      return jsonResponse(
        { ok: false, error: identityOutcome.error },
        502,
        origin,
      );
    }
    const { authUserId, generatedPassword } = identityOutcome.identity;

    const { data: granted, error: grantError } = await grantRole(
      admin,
      input,
      authUserId,
      actorId,
    );
    if (grantError) {
      return jsonResponse(
        { ok: false, error: grantError.message },
        502,
        origin,
      );
    }

    return jsonResponse(
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
    const message = error instanceof Error
      ? error.message
      : "provisioning failed";
    return jsonResponse({ ok: false, error: message }, 500, origin);
  }
};

const handleProvisionRequest = async (
  req: Request,
  origin: string | null,
  env: EnvConfig,
): Promise<Response> => {
  const contextOutcome = await buildAuthorizedContext(req, origin, env);
  if (!contextOutcome.ok) return contextOutcome.response;
  return performProvisioning(contextOutcome.context, origin);
};

Deno.serve((req) => {
  const origin = resolveOrigin(req);

  if (req.method === "OPTIONS") {
    return origin
      ? corsPreflightResponse(origin)
      : jsonResponse({ ok: false, error: "origin not allowed" }, 403, null);
  }
  if (req.method !== "POST") {
    return jsonResponse(
      { ok: false, error: "method not allowed" },
      405,
      origin,
    );
  }
  // A same-value Origin header, when present, must exactly match the
  // configured browser origin -- but Origin is only ever sent by browsers.
  // Non-browser callers (CI/QA service_credential provisioning, curl) send
  // no Origin at all and must not be rejected here; their security boundary
  // is the bearer token + can_grant_staff_role check below, not CORS.
  const requestOrigin = req.headers.get("Origin");
  if (requestOrigin && !origin) {
    return jsonResponse({ ok: false, error: "origin not allowed" }, 403, null);
  }

  const env = readEnvConfig();
  if (!env) {
    return jsonResponse(
      { ok: false, error: "provisioning service is not configured" },
      503,
      origin,
    );
  }

  return handleProvisionRequest(req, origin, env);
});
