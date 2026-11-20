import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import { handleRazorpayWebhook } from "../_shared/razorpayWebhook.ts";

// Razorpay webhook receiver for the retail checkout — CANDIDATE source, SANDBOX.
// verify_jwt is false: the credential is the HMAC-SHA256 signature over the raw body with RAZORPAY_WEBHOOK_SECRET,
// verified before anything is stored or applied. Events are stored durably and applied idempotently by the database.

const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false, autoRefreshToken: false } },
);

Deno.serve((req) =>
  handleRazorpayWebhook(req, {
    secret: (Deno.env.get("RAZORPAY_WEBHOOK_SECRET") ?? "").trim(),
    apply: async (args) => {
      const { data, error } = await admin.rpc("retail_payment_event_apply_v1", args);
      return { data, error: error ? { message: error.message, code: error.code } : null };
    },
    reject: async (payloadHash, reason) =>
      await admin.rpc("retail_payment_event_reject_v1", { p_payload_hash: payloadHash, p_reason: reason }),
  })
);
