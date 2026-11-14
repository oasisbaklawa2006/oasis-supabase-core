/**
 * Deny formerly public arbitrary-recipient outbound modes. The verified
 * provider widget exchange is intentionally not modified by this policy.
 *
 * @param {unknown} mode Requested mode supplied by the caller.
 * @param {Record<string, string>} corsHeaders Existing endpoint CORS headers.
 * @returns {Response | null} A fail-closed response, or null for other modes.
 */
export function rejectLegacyOutboundMode(mode, corsHeaders) {
  if (mode !== "login_otp" && mode !== "order_received") return null;
  return new Response(JSON.stringify({ ok: false, error: "legacy_mode_disabled" }), {
    status: 403,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}
