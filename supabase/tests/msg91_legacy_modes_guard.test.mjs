import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { test } from "node:test";

const source = readFileSync(new URL("../functions/msg91-otp/index.ts", import.meta.url), "utf8");

test("public MSG91 handler contains a literal legacy-mode fail-closed predicate", () => {
  assert.match(
    source,
    /function isLegacyOutboundMode\(mode: unknown\): boolean \{\s*return mode === "login_otp" \|\| mode === "order_received";\s*\}/,
  );
});

test("deny occurs before verified-widget handling and before any legacy send", () => {
  const handler = source.indexOf("serve(async (req) =>");
  const deny = source.indexOf("if (isLegacyOutboundMode(body.mode))", handler);
  const widget = source.indexOf('if (body.mode === "verify_widget")', handler);
  const legacyOtp = source.indexOf('if (body.mode === "login_otp")', handler);
  const legacyNotification = source.indexOf('if (body.mode === "order_received")', handler);
  assert.ok(handler >= 0 && deny > handler, "missing entrypoint deny");
  assert.ok(widget > deny, "verified widget must run only after the deny");
  assert.ok(legacyOtp > widget && legacyNotification > legacyOtp, "legacy branches must follow deny");
  const beforeDeny = source.slice(handler, deny);
  assert.doesNotMatch(beforeDeny, /await\s+(deliver|sendWhatsApp|sendSMS|sendEmail|sendVoice|verifyAccessToken)\s*\(/);
  const guarded = source.slice(deny, widget);
  assert.match(guarded, /error: "legacy_mode_disabled"/);
  assert.match(guarded, /status:\s*403/);
  assert.doesNotMatch(guarded, /await\s+(deliver|sendWhatsApp|sendSMS|sendEmail|sendVoice)\s*\(/);
});

test("provider-verified widget login remains in the source", () => {
  assert.match(source, /if \(body\.mode === "verify_widget"\)/);
  assert.match(source, /await verifyAccessToken\(body\.accessToken\)/);
  assert.match(source, /token_hash:/);
});
