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

test("Core handler checks policy before widget and any legacy send path", () => {
  const start = endpointSource.indexOf("serve(async (req) =>");
  const deny = endpointSource.indexOf("rejectLegacyOutboundMode(body.mode, corsHeaders)", start);
  const widget = endpointSource.indexOf('if (body.mode === "verify_widget")', start);
  const login = endpointSource.indexOf('if (body.mode === "login_otp")', start);
  const order = endpointSource.indexOf('if (body.mode === "order_received")', start);
  assert.ok(start >= 0 && deny > start && widget > deny && login > widget && order > login);
  const pre = endpointSource.slice(start, deny);
  assert.doesNotMatch(pre, /await\s+(deliver|sendWhatsApp|sendSMS|sendEmail|sendVoice|verifyAccessToken)\s*\(/);
  assert.match(endpointSource, /import \{ rejectLegacyOutboundMode \} from "\.\/legacy-outbound-policy\.mjs"/);
  assert.match(endpointSource.slice(deny, widget), /if \(legacyDenied\) return legacyDenied/);
});

test("verified-widget exchange still uses MSG91 verification and token_hash", () => {
  assert.match(endpointSource, /await verifyAccessToken\(body\.accessToken\)/);
  assert.match(endpointSource, /token_hash:/);
});

test("bridge upstream remains widget-only and cannot call rejected legacy modes", () => {
  const bridgeSource = readFileSync(
    new URL("../functions/_shared/msg91SessionBridge.ts", import.meta.url),
    "utf8",
  );
  assert.match(bridgeSource, /if \(body\.mode !== "verify_widget"\)/);
  assert.match(bridgeSource, /return JSON\.stringify\(\{ mode: "verify_widget", accessToken \}\)/);
  assert.match(bridgeSource, /functions\/v1\/msg91-otp/);
  assert.equal(rejectLegacyOutboundMode("verify_widget", corsHeaders), null);
  assert.equal(rejectLegacyOutboundMode("login_otp", corsHeaders)?.status, 403);
  assert.equal(rejectLegacyOutboundMode("order_received", corsHeaders)?.status, 403);
});
