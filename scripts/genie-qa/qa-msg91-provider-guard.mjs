// QA-only staging component. Never copy this into canonical production source.
const QA_URL = "https://skhpmltfjgqitntkmclb.supabase.co";
const VERIFY_URL = "https://api.msg91.com/api/v5/widget/verifyAccessToken";
const denied = () => ({ ok: false, raw: { error: "qa_provider_denied" } });
const record = x => x && typeof x === "object" && !Array.isArray(x) ? x : {};
function approvedPhones(value) {
  if (typeof value !== "string") return null;
  const phones = value.split(",");
  if (phones.length < 2 || phones.length > 8 ||
      phones.some(p => !/^91[6-9][0-9]{9}$/.test(p)) ||
      new Set(phones).size !== phones.length) return null;
  return new Set(phones);
}
function providerPhone(raw, normalize) {
  const r = record(raw), m = record(r.message), d = record(r.data), u = record(d.user);
  // Match canonical firstString precedence; conflicting valid phone fields deny.
  const candidates = [r.message,r.data,m.mobile,m.phone,m.identifier,m.number,
    d.mobile,d.phone,d.identifier,d.number,r.mobile,r.phone,r.identifier,r.number,u.mobile,u.phone]
    .filter(v => typeof v === "string" && v.trim().length > 0);
  const phone = normalize(candidates[0]);
  if (!phone || candidates.some(v => normalize(v) && normalize(v) !== phone)) return null;
  return phone;
}
export function createQaProviderVerifier({ getEnv, verifyCanonical, normalizePhone }) {
  return async function verifyProviderAccessToken({ authKey, accessToken, fetchImpl = globalThis.fetch } = {}) {
    try {
      if (getEnv("SUPABASE_URL") !== QA_URL || getEnv("QA_MSG91_PROVIDER_ENABLED") !== "true") return denied();
      const allow = approvedPhones(getEnv("QA_MSG91_TEST_PHONE_ALLOWLIST"));
      // The QA-scoped provider credential must be explicitly configured. Never
      // use a production key; the owner verifies its isolated provider custody.
      if (!allow || typeof authKey !== "string" || !authKey.trim() ||
          typeof accessToken !== "string" || !accessToken.trim() || accessToken.length > 8192 ||
          typeof fetchImpl !== "function") return denied();
      const result = await verifyCanonical({
        authKey, accessToken,
        fetchImpl: (url, init) => {
          if (url !== VERIFY_URL || init?.method !== "POST") throw new Error("qa_provider_destination_denied");
          return fetchImpl(url, { ...init, redirect: "error" });
        },
        log: () => {}, // No provider response, token, phone or key in logs.
      });
      if (result?.ok !== true || result.raw?.type !== "success") return denied();
      const phone = providerPhone(result.raw, normalizePhone);
      if (!phone || !allow.has(phone)) return denied();
      // Both canonical consumers only need a verified phone and success type.
      return { ok: true, raw: { type: "success", message: phone } };
    } catch {
      return denied();
    }
  };
}
