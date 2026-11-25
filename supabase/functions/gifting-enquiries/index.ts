import { createClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  handleGiftingEnquiryRequest,
  type ReceiveFn,
} from "../_shared/giftingEnquiryReceiver.ts";

// Server-to-server receiver for Gifting website enquiries (Central #677).
// verify_jwt is false: the Connect bearer token is the credential and is verified,
// scoped and bound to the `gifting_enquiries_v1` profile inside the database RPC.
// Deployment is a governed release step; this source is a candidate until then.

const admin = createClient(
  Deno.env.get("SUPABASE_URL") ?? "",
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "",
  { auth: { persistSession: false, autoRefreshToken: false } },
);

const receive: ReceiveFn = async (token, sourceLeadId, payload) => {
  const { data, error } = await admin.rpc("gifting_enquiry_receive_v1", {
    p_token: token,
    p_source_lead_id: sourceLeadId,
    p_payload: payload,
  });
  return {
    data,
    error: error ? { message: error.message, code: error.code } : null,
  };
};

Deno.serve((req) => handleGiftingEnquiryRequest(req, receive));
