// Provider-verified MSG91 identity exchange, expressed over injected dependencies so the
// complete decision flow is behaviourally testable without Deno, Supabase or MSG91.
//
// Identity selection is delegated to the database authority (migration
// 20261110150000_msg91_identity_resolution_authority_v1): ONE transaction, per-phone
// advisory lock, indexed canonical matching. This module never scans tables or the Auth
// user population and never deletes an Auth identity.
//
// deps = {
//   rpc(name, args) -> Promise<{ data, error }>           // service_role PostgREST RPC
//   getAuthUserById(id) -> Promise<{ data, error }>        // auth.admin.getUserById
//   createAuthUser(attrs) -> Promise<{ data, error }>      // auth.admin.createUser
//   bindInternalEmail(id, email) -> Promise<{ error }>     // auth.admin.updateUserById
//   mintTokenHash(email) -> Promise<{ tokenHash } | { error }>
//   log(msg) -> void                                       // non-sensitive diagnostics only
// }
// Returns { status, body } where body never contains provider secrets.

import { canonicalIndianPhone } from "./strict-phone-match.mjs";

const internalEmailFor = (canonical) => `${canonical}@phone.oasis.local`;

const rpcObject = (res) => {
  if (!res || res.error || !res.data) return null;
  const d = Array.isArray(res.data) ? res.data[0] : res.data;
  return d && typeof d === "object" && typeof d.status === "string" ? d : null;
};

const CONFLICT_SETTLE_MS = 300;
const failure = (error, status) => ({ status, body: { ok: false, error } });

export async function exchangeVerifiedPhone(deps, canonical) {
  const e164 = `+${canonical}`;
  let resolved = rpcObject(await deps.rpc("resolve_msg91_identity_v1", { p_verified_phone: canonical }));
  if (!resolved) return failure("identity_lookup_failed", 500);
  if (resolved.status === "phone_invalid") return failure("phone_invalid", 401);
  if (resolved.status === "duplicate_phone_identity") return failure("duplicate_phone_identity", 409);
  if (resolved.status === "ambiguous_phone_identity") return failure("ambiguous_phone_identity", 409);

  // A concurrent request may be mid-way through creating the Auth identity (row visible before its
  // phone/email confirmation lands), which classifies as a conflict only transiently. Re-resolve once
  // after a short pause; a genuine conflict (pre-registered or foreign identity) is stable and still fails.
  if (resolved.status === "none" && resolved.auth_state === "conflict") {
    await (deps.sleep ?? ((ms) => new Promise((r) => setTimeout(r, ms))))(CONFLICT_SETTLE_MS);
    const again = rpcObject(await deps.rpc("resolve_msg91_identity_v1", { p_verified_phone: canonical }));
    if (!again) return failure("identity_lookup_failed", 500);
    resolved = again;
    if (resolved.status === "duplicate_phone_identity") return failure("duplicate_phone_identity", 409);
    if (resolved.status === "ambiguous_phone_identity") return failure("ambiguous_phone_identity", 409);
  }

  let userId;
  let email;
  let isNew = false;

  if (resolved.status === "existing") {
    const publicId = String(resolved.public_user_id);
    // The deterministic internal email may only ever belong to the matched identity.
    if (resolved.auth_identifier_ambiguous) return failure("auth_recovery_identity_conflict", 409);
    if (resolved.auth_internal_email_user_id && resolved.auth_internal_email_user_id !== publicId) {
      return failure("auth_recovery_identity_conflict", 409);
    }
    // A different Auth user that owns the verified phone is a conflicting phone owner: never hand the
    // session of the public identity's Auth user while another Auth identity holds this number.
    if (resolved.auth_phone_user_id && resolved.auth_phone_user_id !== publicId) {
      return failure("auth_recovery_identity_conflict", 409);
    }
    const { data, error } = await deps.getAuthUserById(publicId);
    if (error) {
      if (error.status !== 404) return failure("identity_lookup_failed", 500);
      // Bridge recovery signal for an eligible legacy placeholder with no Auth user.
      return failure("phone_linked_to_missing_auth_identity", 409);
    }
    if (!data?.user) return failure("phone_linked_to_missing_auth_identity", 409);
    if (data.user.id !== publicId) return failure("auth_recovery_identity_conflict", 409);
    // public.users phone/mobile_number/secondary_phones are profile data and were
    // historically self-writable. They are never sufficient to mint a login
    // session. Bind the provider-verified phone to the SAME Auth identity only
    // when GoTrue has independently confirmed that exact full phone number.
    // Unconfirmed legacy accounts must complete a controlled verification
    // process rather than inherit a session from editable profile fields.
    if (!data.user.phone_confirmed_at || canonicalIndianPhone(data.user.phone) !== canonical) {
      return failure("verified_auth_phone_required", 409);
    }
    userId = data.user.id;
    email = data.user.email || "";
    if (!email) {
      email = internalEmailFor(canonical);
      const bound = await deps.bindInternalEmail(userId, email);
      if (bound?.error) return failure("auth_email_bind_failed", 500);
    }
  } else if (resolved.status === "none") {
    let authId = null;
    if (resolved.auth_state === "orphan_recoverable") authId = String(resolved.auth_user_id);
    else if (resolved.auth_state === "conflict") return failure("auth_recovery_identity_conflict", 409);

    if (!authId) {
      const aliasEmail = internalEmailFor(canonical);
      const created = await deps.createAuthUser({
        phone: e164,
        phone_confirm: true,
        email: aliasEmail,
        email_confirm: true,
        app_metadata: {
          msg91_verified_phone_alias: { email: aliasEmail, nonce: crypto.randomUUID() },
        },
      });
      if (!created?.error && created?.data?.user?.id) {
        authId = created.data.user.id;
      } else {
        // Duplicate or uncertain create: a concurrent request (or an earlier partially
        // failed attempt) may own the deterministic identity. Re-resolve under the lock
        // authority; Auth uniqueness on email/phone guarantees at most one winner.
        resolved = rpcObject(await deps.rpc("resolve_msg91_identity_v1", { p_verified_phone: canonical }));
        if (!resolved) return failure("identity_lookup_failed", 500);
        if (resolved.status === "none" && resolved.auth_state === "orphan_recoverable") {
          authId = String(resolved.auth_user_id);
        } else if (resolved.status === "existing") {
          // A concurrent request already completed provisioning: continue as existing login.
          return exchangeVerifiedPhone(deps, canonical);
        } else {
          deps.log("auth_user_create_failed");
          return failure(resolved.auth_state === "conflict" ? "auth_recovery_identity_conflict" : "auth_user_create_failed",
            resolved.auth_state === "conflict" ? 409 : 500);
        }
      }
    }

    const bind = rpcObject(await deps.rpc("bind_msg91_pending_profile_v1", { p_verified_phone: canonical, p_auth_user_id: authId }));
    if (!bind) return failure("pending_profile_create_failed", 500);
    if (bind.status !== "created" && bind.status !== "exists") return failure("pending_profile_identity_conflict", 409);
    isNew = bind.status === "created";
    userId = authId;
    email = internalEmailFor(canonical);
  } else {
    return failure("identity_lookup_failed", 500);
  }

  const mint = await deps.mintTokenHash(email);
  if ("error" in mint) return failure(mint.error, 502);
  return {
    status: 200,
    body: {
      ok: true,
      type: "success",
      user_id: userId,
      email,
      phone: e164,
      is_new: isNew,
      approved_b2b_pending_claim: Boolean(resolved.approved_b2b_pending_claim),
      token_hash: mint.tokenHash,
    },
  };
}
