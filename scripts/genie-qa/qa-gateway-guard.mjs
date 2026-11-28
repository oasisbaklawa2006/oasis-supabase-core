// QA-only. Do not import into the canonical Central gateway.
export function allowQaBuyerPreflight(getEnv, body) {
  try {
    if (getEnv("SUPABASE_URL") !== "https://skhpmltfjgqitntkmclb.supabase.co" ||
        getEnv("QA_MSG91_PROVIDER_ENABLED") !== "true" ||
        !getEnv("QA_MSG91_PROVIDER_AUTH_KEY") || getEnv("MSG91_AUTH_KEY") ||
        getEnv("OPENAI_API_KEY") || body?.mode !== "preflight" ||
        body?.channel !== "mobile" || typeof body.identifier !== "string") return false;
    const key = getEnv("QA_MSG91_PROVIDER_AUTH_KEY");
    if (typeof key !== "string" || !key.trim() || key !== key.trim()) return false;
    const raw = getEnv("QA_MSG91_TEST_PHONE_ALLOWLIST");
    if (typeof raw !== "string") return false;
    const phones = raw.split(",");
    return phones.length >= 2 && phones.length <= 8 &&
      phones.every(p => /^91[6-9][0-9]{9}$/.test(p)) &&
      new Set(phones).size === phones.length &&
      phones.includes(body.identifier);
  } catch {
    return false;
  }
}
