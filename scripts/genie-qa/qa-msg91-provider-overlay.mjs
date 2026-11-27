// Staged only inside a QA scratch deployment closure.
import { verifyProviderAccessToken as verifyCanonical } from "./provider-verify-canonical.mjs";
import { canonicalIndianPhone } from "./strict-phone-match.mjs";
import { createQaProviderVerifier } from "./qa-msg91-provider-guard.mjs";
export const MSG91_VERIFY_URL = "https://api.msg91.com/api/v5/widget/verifyAccessToken";
export const MSG91_VERIFY_TIMEOUT_MS = 10_000;
export const verifyProviderAccessToken = createQaProviderVerifier({
  getEnv: name => globalThis.Deno.env.get(name),
  verifyCanonical,
  normalizePhone: canonicalIndianPhone,
});
