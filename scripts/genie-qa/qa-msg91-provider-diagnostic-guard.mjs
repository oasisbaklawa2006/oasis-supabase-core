// QA-only staging component. Never copy this into canonical production source.
const QA_URL = "https://skhpmltfjgqitntkmclb.supabase.co";
const VERIFY_URL = "https://api.msg91.com/api/v5/widget/verifyAccessToken";
const denied = () => ({ ok: false, raw: { error: "qa_provider_denied" } });
// Only code-owned literals reach logging. Never serialize provider payloads, error text,
// credentials, token, identifiers, or user-controlled status/type strings.
const CODES = new Set(["activation_disabled","allowlist_invalid",
  "key_invalid","legacy_key_present","token_invalid","transport_invalid",
  "destination_denied","provider_http_auth_rejected","provider_http_other_rejected",
  "provider_timeout","provider_unreachable","provider_payload_rejected",
  "provider_token_invalid","provider_token_already_verified","provider_token_missing",
  "verified_phone_missing_or_invalid","verified_phone_conflict","phone_not_allowlisted",
  "unexpected_error","verified"]);
// Match documented MSG91 denial messages exactly after case and whitespace normalization.
const TOKEN_DENIAL_CODES = new Map([
  ["invalid access token", "provider_token_invalid"],
  ["access token already verified", "provider_token_already_verified"],
  ["access token field is required", "provider_token_missing"],
]);
function emit(log, code) {
  if (!CODES.has(code)) return;
  try { log("GENIE_QA_MSG91_DIAGNOSTIC:" + code); } catch { /* diagnostics cannot change authorization */ }
}
const record = x => x && typeof x === "object" && !Array.isArray(x) ? x : {};
function approvedPhones(value) {
  if (typeof value !== "string") return null;
  const phones = value.split(",");
  if (phones.length < 2 || phones.length > 8 ||
      phones.some(p => !/^91[6-9][0-9]{9}$/.test(p)) ||
      new Set(phones).size !== phones.length) return null;
  return new Set(phones);
}
function strictProviderPhone(value, normalize) {
  if (typeof value !== "string" || !/^[+0-9 ()-]+$/.test(value)) return null;
  return normalize(value);
}
function providerPhone(raw, normalize) {
  const r = record(raw), m = record(r.message), d = record(r.data), u = record(d.user);
  // Match canonical firstString precedence; conflicting valid phone fields deny.
  const candidates = [r.message,r.data,m.mobile,m.phone,m.identifier,m.number,
    d.mobile,d.phone,d.identifier,d.number,r.mobile,r.phone,r.identifier,r.number,u.mobile,u.phone]
    .filter(v => typeof v === "string" && v.trim().length > 0);
  const phone = strictProviderPhone(candidates[0], normalize);
  if (!phone) return { code: "verified_phone_missing_or_invalid" };
  if (candidates.some(v => strictProviderPhone(v, normalize) !== phone)) return { code: "verified_phone_conflict" };
  return { phone };
}
export function createQaProviderVerifier({ getEnv, verifyCanonical, normalizePhone, diagnosticLog = console.info }) {
  return async function verifyProviderAccessToken({ authKey, accessToken, fetchImpl = globalThis.fetch } = {}) {
    const reject = code => { emit(diagnosticLog, code); return denied(); };
    try {
      if (getEnv("SUPABASE_URL") !== QA_URL) return denied(); // no diagnostics outside QA
      if (getEnv("QA_MSG91_PROVIDER_ENABLED") !== "true") return reject("activation_disabled");
      const allow = approvedPhones(getEnv("QA_MSG91_TEST_PHONE_ALLOWLIST"));
      const qaKey = getEnv("QA_MSG91_PROVIDER_AUTH_KEY");
      if (!allow) return reject("allowlist_invalid");
      if (typeof qaKey !== "string" || !qaKey.trim() ||
          qaKey !== qaKey.trim() || authKey !== qaKey) return reject("key_invalid");
      if (getEnv("MSG91_AUTH_KEY")) return reject("legacy_key_present");
      if (typeof accessToken !== "string" || !accessToken.trim() || accessToken.length > 8192) return reject("token_invalid");
      if (typeof fetchImpl !== "function") return reject("transport_invalid");
      let status = 0, badDestination = false;
      const result = await verifyCanonical({
        authKey: qaKey, accessToken,
        fetchImpl: async (url, init) => {
          if (url !== VERIFY_URL || init?.method !== "POST") {
            badDestination = true;
            throw new Error("qa_provider_destination_denied");
          }
          const response = await fetchImpl(url, { ...init, redirect: "error" });
          status = Number.isInteger(response?.status) && response.status >= 100 && response.status <= 599 ? response.status : 0;
          return response;
        },
        log: () => {}, // No provider response, token, phone or key in logs.
      });
      if (result?.ok !== true || result.raw?.type !== "success") {
        if (badDestination) return reject("destination_denied");
        if (status === 401 || status === 403) return reject("provider_http_auth_rejected");
        if (status && (status < 200 || status >= 300)) return reject("provider_http_other_rejected");
        if (!status && result?.raw?.error === "provider_timeout") return reject("provider_timeout");
        if (!status && result?.raw?.error === "provider_unreachable") return reject("provider_unreachable");
        const message = result?.raw?.message;
        const tokenDenial = status >= 200 && status < 300 && result?.raw?.type === "error" &&
          typeof message === "string" && message.length <= 64
          ? TOKEN_DENIAL_CODES.get(message.trim().toLowerCase())
          : undefined;
        return reject(tokenDenial ?? "provider_payload_rejected");
      }
      const parsed = providerPhone(result.raw, normalizePhone);
      if (!parsed.phone) return reject(parsed.code);
      if (!allow.has(parsed.phone)) return reject("phone_not_allowlisted");
      emit(diagnosticLog, "verified");
      return { ok: true, raw: { type: "success", message: parsed.phone } };
    } catch {
      return reject("unexpected_error");
    }
  };
}
