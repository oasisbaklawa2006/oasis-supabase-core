// MSG91 widget access-token verification with an explicit timeout and injectable fetch.
// Any transport failure, timeout, non-2xx, non-JSON body or non-"success" type is a
// verification failure; callers must never treat it as a verified phone.
export const MSG91_VERIFY_URL = "https://api.msg91.com/api/v5/widget/verifyAccessToken";
export const MSG91_VERIFY_TIMEOUT_MS = 10_000;

export async function verifyProviderAccessToken({ authKey, accessToken, fetchImpl = fetch, timeoutMs = MSG91_VERIFY_TIMEOUT_MS, log = (..._args) => {} }) {
  if (!authKey) { log({ ok: false, error: "auth_key_unavailable", auth_key_present: false }); return { ok: false, raw: { error: "auth_key_unavailable" } }; }
  try {
    const res = await fetchImpl(MSG91_VERIFY_URL, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", authkey: authKey },
      body: JSON.stringify({ "access-token": accessToken }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    const parsed = await res.json().catch(() => ({}));
    const raw = parsed && typeof parsed === "object" && !Array.isArray(parsed) ? parsed : {};
    log({ ok: res.ok, status: res.status, type: typeof raw.type === "string" ? raw.type : "unknown" });
    return { ok: res.ok === true && raw.type === "success", raw };
  } catch (e) {
    const name = e instanceof Error ? e.name : "unknown";
    log({ ok: false, error: name });
    return { ok: false, raw: { error: name === "TimeoutError" || name === "AbortError" ? "provider_timeout" : "provider_unreachable" } };
  }
}
