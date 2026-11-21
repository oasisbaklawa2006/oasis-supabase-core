// INERT QA COMMISSIONING OVERLAY ONLY. NEVER COPY INTO PRODUCTION SOURCE.
// Both msg91-otp and msg91-session-bridge import this module from the
// QA-only disposable deployment workdir. No provider HTTP request is possible,
// even if an operator changes MSG91_AUTH_KEY during or after commissioning.
// A later real-provider UAT needs a separately approved canonical deployment.
export const MSG91_VERIFY_URL = "qa-inert-provider-disabled";
export const MSG91_VERIFY_TIMEOUT_MS = 0;

export async function verifyProviderAccessToken(_options = {}) {
  return { ok: false, raw: { error: "qa_provider_disabled" } };
}
