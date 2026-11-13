// Production wiring of the identity-flow dependencies over a service_role Supabase client.
// Kept separate from index.ts so exactly this wiring can be exercised by tests.
export async function mintMagicTokenHash(admin, email, log = (..._args) => {}) {
  if (!admin) return { error: "session_token_mint_failed" };
  try {
    const { data, error } = await admin.auth.admin.generateLink({ type: "magiclink", email });
    if (error || !data) {
      log("token mint provider error");
      return { error: "session_token_mint_failed" };
    }
    const props = data.properties || {};
    if (typeof props.hashed_token === "string" && props.hashed_token) return { tokenHash: props.hashed_token };
    const link = typeof props.action_link === "string" ? props.action_link : "";
    const m = link.match(/token_hash=([^&]+)/) || link.match(/[?#&]token=([^&]+)/);
    if (m) return { tokenHash: decodeURIComponent(m[1]) };
    return { error: "session_token_mint_failed" };
  } catch (e) {
    log(`token mint threw: ${e instanceof Error ? e.name : "unknown"}`);
    return { error: "session_token_mint_failed" };
  }
}

export function createExchangeDeps(admin, log = (..._args) => {}) {
  return {
    rpc: (name, args) => admin.rpc(name, args),
    getAuthUserById: (id) => admin.auth.admin.getUserById(id),
    createAuthUser: (attrs) => admin.auth.admin.createUser(attrs),
    bindInternalEmail: (id, email) => admin.auth.admin.updateUserById(id, {
      email,
      email_confirm: true,
      app_metadata: {
        msg91_verified_phone_alias: { email: email, nonce: crypto.randomUUID() },
      },
    }),
    mintTokenHash: (email) => mintMagicTokenHash(admin, email, log),
    log,
  };
}
