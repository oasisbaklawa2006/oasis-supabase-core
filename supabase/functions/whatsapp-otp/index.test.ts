import { legacyWhatsAppOtpRetiredResponse } from "./index.ts";

Deno.test("legacy WhatsApp OTP retires without issuing authentication", async () => {
  const response = legacyWhatsAppOtpRetiredResponse();
  if (response.status !== 410) throw new Error("legacy endpoint must be gone");
  const result = await response.json();
  if (
    result.success !== false || result.error !== "LEGACY_WHATSAPP_OTP_RETIRED"
  ) {
    throw new Error("retired response must be stable and unambiguous");
  }
});

Deno.test("retired endpoint response contains no secrets or customer details", async () => {
  const response = legacyWhatsAppOtpRetiredResponse();
  const body = await response.text();
  for (
    const forbidden of ["token", "otp_code", "phone", "access_token", "message"]
  ) {
    if (body.includes(forbidden)) {
      throw new Error("retired endpoint response discloses unexpected data");
    }
  }
  if (response.headers.has("Access-Control-Allow-Origin")) {
    throw new Error("retired endpoint must not expose wildcard CORS");
  }
  if (response.headers.get("Cache-Control") !== "no-store") {
    throw new Error("retired endpoint must prohibit response caching");
  }
});
