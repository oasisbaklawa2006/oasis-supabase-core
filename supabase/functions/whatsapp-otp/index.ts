/**
 * WA-100 P0 — Core-authoritative legacy WhatsApp OTP retirement source.
 *
 * Production currently hosts a historical Central-origin function which
 * performs unauthenticated OTP issuance and session generation. The protected
 * production release must replace that runtime with this non-mutating 410
 * tombstone only after owner-approved dependency and rollback verification.
 *
 * No credential, body, phone, IP address, OTP, Auth or database access occurs.
 * Do not add this candidate to broad Preview deployment configuration.
 */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";

export function legacyWhatsAppOtpRetiredResponse(): Response {
  return new Response(
    JSON.stringify({
      success: false,
      error: "LEGACY_WHATSAPP_OTP_RETIRED",
    }),
    {
      status: 410,
      headers: {
        "Content-Type": "application/json",
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
      },
    },
  );
}

if (import.meta.main) {
  serve(() => legacyWhatsAppOtpRetiredResponse());
}
