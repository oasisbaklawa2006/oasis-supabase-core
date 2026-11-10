import assert from "node:assert/strict";
import { test } from "node:test";
import { readFileSync } from "node:fs";
import { rejectLegacyOutboundMode } from "../functions/msg91-otp/legacy-outbound-policy.mjs";

const endpointSource = readFileSync(new URL("../functions/msg91-otp/index.ts", import.meta.url), "utf8");
const corsHeaders = { "Access-Control-Allow-Origin": "*" };

test("anonymous legacy outbound requests are denied without echoing OTP or recipient", async () => {
  for (const mode of ["login_otp", "order_received"]) {
    const result = rejectLegacyOutboundMode(mode, corsHeaders);
    assert.ok(result instanceof Response);
    assert.equal(result.status, 403);
    assert.equal(result.headers.get("content-type"), "application/json");
    assert.equal(result.headers.get("access-control-allow-origin"), "*");
    assert.deepEqual(await result.json(), { ok: false, error: "legacy_mode_disabled" });
  }
});

test("other modes cannot trigger outbound denial; widget verification remains available", () => {
  for (const mode of ["verify_widget", "other", null, 0, {}, undefined]) {
    assert.equal(rejectLegacyOutboundMode(mode, corsHeaders), null);
  }
});

test("Core handler denies legacy modes before provider verification", () => {
  const start = endpointSource.indexOf("serve(async (req) =>");
  const deny = endpointSource.indexOf("rejectLegacyOutboundMode(body.mode, corsHeaders)", start);
  const widget = endpointSource.indexOf('if (body.mode === "verify_widget")', start);
  assert.ok(start >= 0 && deny > start && widget > deny);
  assert.match(endpointSource, /import \{ rejectLegacyOutboundMode \} from "\.\/legacy-outbound-policy\.mjs"/);
  assert.match(endpointSource.slice(deny, widget), /if \(legacyDenied\) return legacyDenied/);
  assert.doesNotMatch(endpointSource.slice(start, deny), /await\s+(deliver|sendWhatsApp|sendSMS|sendEmail|sendVoice|verifyAccessToken)\s*\(/);
});

test("disabled legacy modes leave no executable OTP generation or arbitrary outbound send code", () => {
  assert.doesNotMatch(endpointSource, /\bMath\.random\b|\bgenOtp\b/);
  assert.doesNotMatch(endpointSource, /\b(?:sendWhatsApp|sendSMS|sendEmail|sendVoice|deliver)\s*\(/);
  assert.doesNotMatch(endpointSource, /if \(body\.mode === "(?:login_otp|order_received)"\)/);
  assert.doesNotMatch(endpointSource, /authKey:\s*maskSecret|accessToken:\s*maskSecret|\braw,\s*\}\)\)/);
  assert.match(endpointSource, /error: "internal_error"/);
});

test("verified-widget exchange still uses MSG91 verification and token_hash", () => {
  assert.match(endpointSource, /await verifyAccessToken\(body\.accessToken\)/);
  assert.match(readFileSync(new URL("../functions/msg91-otp/identity-flow.mjs", import.meta.url), "utf8"), /token_hash:/);
});

test("bridge upstream remains widget-only and cannot call rejected legacy modes", () => {
  const bridgeSource = readFileSync(
    new URL("../functions/_shared/msg91SessionBridge.ts", import.meta.url),
    "utf8",
  );
  assert.match(bridgeSource, /export function validateBridgeRequest\(/);
  assert.match(bridgeSource, /export function buildUpstreamVerifyPayload\(/);
  assert.match(bridgeSource, /return JSON\.stringify\(\{ mode: "verify_widget", accessToken \}\)/);
  assert.match(bridgeSource, /functions\/v1\/msg91-otp/);
  assert.equal(rejectLegacyOutboundMode("verify_widget", corsHeaders), null);
  assert.equal(rejectLegacyOutboundMode("login_otp", corsHeaders)?.status, 403);
  assert.equal(rejectLegacyOutboundMode("order_received", corsHeaders)?.status, 403);
});

test("identity matching rejects embedded suffixes and non-Indian numbers", async () => {
  const { canonicalIndianPhone, phoneEquals, anyPhoneEquals } = await import("../functions/msg91-otp/strict-phone-match.mjs");
  assert.equal(canonicalIndianPhone("+91 98765 43210"), "919876543210");
  assert.equal(canonicalIndianPhone("09876543210"), "919876543210");
  assert.equal(phoneEquals("98765-43210", "+91 9876543210"), true);
  assert.equal(phoneEquals("9919876543210", "+91 9876543210"), false);
  assert.equal(phoneEquals("1239876543210", "+91 9876543210"), false);
  assert.equal(phoneEquals("98765432101", "+91 9876543210"), false);
  assert.equal(phoneEquals("+1 9876543210", "+91 9876543210"), false);
  assert.equal(anyPhoneEquals(["9919876543210","09876543210"],"919876543210"),true);
  assert.equal(anyPhoneEquals(["9919876543210"],"919876543210"),false);
});
test("identity selection is delegated to the database authority; no multi-request scans remain", () => {
  const flowSource = readFileSync(new URL("../functions/msg91-otp/identity-flow.mjs", import.meta.url), "utf8");
  assert.match(endpointSource, /import \{ exchangeVerifiedPhone \} from "\.\/identity-flow\.mjs"/);
  assert.match(endpointSource, /await exchangeVerifiedPhone\(createExchangeDeps\(supabaseAdmin, logDiagnostic\), normalized\)/);
  assert.match(flowSource, /resolve_msg91_identity_v1/);
  assert.match(flowSource, /bind_msg91_pending_profile_v1/);
  for (const src of [endpointSource, flowSource]) {
    assert.doesNotMatch(src, /listUsers\(/);
    assert.doesNotMatch(src, /\.admin\.deleteUser\(/);
    assert.doesNotMatch(src, /\.ilike\(|\.range\(|SECONDARY_PAGE_SIZE|CANDIDATE_LIMIT/);
    assert.doesNotMatch(src, /from\("users"\)|from\("b2b_applications"\)|from\("companies"\)/);
  }
  assert.match(flowSource, /phone_linked_to_missing_auth_identity/);
  assert.match(flowSource, /error\.status !== 404/);
});
