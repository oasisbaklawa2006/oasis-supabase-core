import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { handleRetailCheckoutRequest, extractVerifiedPhone, type CheckoutDeps } from "../_shared/retailCheckout.ts";
import { createRazorpayOrder, sandboxConfig } from "../_shared/razorpayOrders.ts";
import { verifyProviderAccessToken } from "../msg91-otp/provider-verify.mjs";
import { canonicalIndianPhone } from "../msg91-otp/strict-phone-match.mjs";

// Retail (B2C) checkout boundary — CANDIDATE source, SANDBOX payments only (rzp_test_ keys; live keys refused).
// verify_jwt is false: the credential is a retail guest session token (hashed in the database) obtained by proving
// a phone through the MSG91 widget. Every commercial action is gated by approved retail_commerce_settings.
// Deployment is a governed release step; this source activates nothing.

const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const sandbox = sandboxConfig(Deno.env.get("RAZORPAY_KEY_ID"), Deno.env.get("RAZORPAY_KEY_SECRET"));
const msg91AuthKey = (Deno.env.get("MSG91_AUTH_KEY") ?? "").trim();

const deps: CheckoutDeps = {
  rpc: async (name, args) => {
    const { data, error } = await admin.rpc(name, args);
    return { data, error: error ? { message: error.message, code: error.code, details: error.details } : null };
  },
  verifyPhone: async (accessToken) => {
    const result = await verifyProviderAccessToken({ authKey: msg91AuthKey, accessToken });
    if (!result.ok) return { ok: false };
    const phone = canonicalIndianPhone(extractVerifiedPhone(result.raw as Record<string, unknown>) ?? "");
    return phone ? { ok: true, phone } : { ok: false };
  },
  razorpay: sandbox.ok
    ? { keyId: sandbox.config.keyId, create: (input) => createRazorpayOrder(sandbox.config, input) }
    : null,
  allowedOrigins: (Deno.env.get("RETAIL_ALLOWED_ORIGINS") ?? "").split(",").map((s) => s.trim()).filter(Boolean),
};

Deno.serve((req) => handleRetailCheckoutRequest(req, deps));
