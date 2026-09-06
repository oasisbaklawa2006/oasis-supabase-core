import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";
import {
  buildGovernedCandidate,
  extractPayloadIdentityFields,
  extractStaffMentionedClient,
  mapGovernedCustomerRow,
  resolveWebhookCompany,
  shouldBlockSenderPhoneInference,
  type GovernedCustomerRow,
} from "./resolveWebhookCompany.ts";

function assert(condition: unknown, message = "assertion failed"): asserts condition {
  if (!condition) throw new Error(message);
}

function mockSupabaseForRpc(
  row: GovernedCustomerRow,
  accountManagerId: string | null = null,
): SupabaseClient {
  return {
    rpc: async () => ({ data: [row], error: null }),
    from: () => ({
      select: () => ({
        eq: () => ({
          maybeSingle: async () => ({
            data: accountManagerId ? { account_manager_id: accountManagerId } : null,
            error: null,
          }),
        }),
      }),
    }),
  } as unknown as SupabaseClient;
}

Deno.test("unique explicit company_id binding resolves via governed RPC", async () => {
  const admin = mockSupabaseForRpc({
    company_id: "66000000-0000-0000-0000-000000000002",
    business_name: "P66 Customer Alpha",
    gst_number: "29AAAAA0000A1Z1",
    payment_terms: null,
    is_frozen: false,
    resolution_status: "RESOLVED",
    match_method: "EXPLICIT_CANDIDATE_COMPANY_ID",
    confidence: 1,
    details: { company_id: "66000000-0000-0000-0000-000000000002" },
  }, "mgr-1");

  const result = await resolveWebhookCompany(admin, {
    contactId: "66000000-0000-0000-0000-000000000011",
    profileName: "Customer",
    messageBody: "Need 10 boxes",
    senderIsStaffProxy: false,
    explicitCompanyId: "66000000-0000-0000-0000-000000000002",
  });

  assert(result.resolutionStatus === "RESOLVED");
  assert(result.companyId === "66000000-0000-0000-0000-000000000002");
  assert(result.matchMethod === "EXPLICIT_CANDIDATE_COMPANY_ID");
  assert(result.accountManagerId === "mgr-1");
});

Deno.test("shared phone ambiguity fails closed without company assignment", async () => {
  const admin = mockSupabaseForRpc({
    company_id: null,
    business_name: null,
    gst_number: null,
    payment_terms: null,
    is_frozen: false,
    resolution_status: "AMBIGUOUS",
    match_method: "MULTIPLE_PHONE_MATCHES",
    confidence: 0.5,
    details: {
      phone: "919800000099",
      matched_company_ids: [
        "66000000-0000-0000-0000-000000000004",
        "66000000-0000-0000-0000-000000000005",
      ],
    },
  });

  const result = await resolveWebhookCompany(admin, {
    contactId: "66000000-0000-0000-0000-000000000013",
    profileName: "Shared Phone",
    messageBody: "Send order",
    senderIsStaffProxy: false,
  });

  assert(result.resolutionStatus === "AMBIGUOUS");
  assert(result.companyId === null);
  assert(result.matchMethod === "MULTIPLE_PHONE_MATCHES");
});

Deno.test("forwarded employee relay without candidate stays unresolved", async () => {
  const admin = mockSupabaseForRpc({
    company_id: null,
    business_name: null,
    gst_number: null,
    payment_terms: null,
    is_frozen: false,
    resolution_status: "UNRESOLVED",
    match_method: "NO_MATCH",
    confidence: 0,
    details: { contact_phone: "919800000095" },
  });

  const result = await resolveWebhookCompany(admin, {
    contactId: "66000000-0000-0000-0000-000000000010",
    profileName: "P66 Employee Relay",
    messageBody: "Forwarded message\nNeed 5 boxes baklawa",
    senderIsStaffProxy: true,
    isForwarded: true,
    originalCommunicatorPhone: null,
  });

  assert(result.resolutionStatus === "UNRESOLVED");
  assert(result.companyId === null);
  assert(shouldBlockSenderPhoneInference({
    contactId: "66000000-0000-0000-0000-000000000010",
    senderIsStaffProxy: true,
    isForwarded: true,
  }));
});

Deno.test("fuzzy name/GST collision surfaces AMBIGUOUS from governed RPC", async () => {
  const admin = mockSupabaseForRpc({
    company_id: null,
    business_name: null,
    gst_number: null,
    payment_terms: null,
    is_frozen: false,
    resolution_status: "AMBIGUOUS",
    match_method: "MULTIPLE_GST_MATCHES",
    confidence: 0.5,
    details: {
      candidate_gst: "29AAAAA0000A1Z1",
      matched_company_ids: ["c1", "c2"],
    },
  });

  const candidate = buildGovernedCandidate({
    contactId: "contact-1",
    messageBody: "GST 29AAAAA0000A1Z1 order for sweets",
    senderIsStaffProxy: false,
  });
  assert(candidate.gst_number === "29AAAAA0000A1Z1");
  assert(!candidate.company_name?.includes("%"));

  const result = await resolveWebhookCompany(admin, {
    contactId: "contact-1",
    messageBody: "GST 29AAAAA0000A1Z1 order for sweets",
    senderIsStaffProxy: false,
  });

  assert(result.resolutionStatus === "AMBIGUOUS");
  assert(result.companyId === null);
});

Deno.test("cross-company retarget is not available in governed webhook resolver", async () => {
  const source = await Deno.readTextFile(
    new URL("../../whatsapp-webhook/index.ts", import.meta.url),
  );
  assert(!source.includes("[CONTEXT STITCH]"));
  assert(!source.includes(".update({ company_id:"));
  assert(!source.includes('status: "shadow"'));
  assert(!source.includes("Shadow client created"));
});

Deno.test("unresolved governed RPC fails closed", async () => {
  const admin = mockSupabaseForRpc({
    company_id: null,
    business_name: null,
    gst_number: null,
    payment_terms: null,
    is_frozen: false,
    resolution_status: "UNRESOLVED",
    match_method: "NO_MATCH",
    confidence: 0,
    details: { contact_phone: "919800000011" },
  });

  const result = await resolveWebhookCompany(admin, {
    contactId: "66000000-0000-0000-0000-000000000011",
    profileName: "Unknown Lead",
    messageBody: "Hello",
    senderIsStaffProxy: false,
  });

  assert(result.resolutionStatus === "UNRESOLVED");
  assert(result.companyId === null);
});

Deno.test("staff relay explicit client mention passes exact candidate only", () => {
  const mentioned = extractStaffMentionedClient('Order for P66 Customer Beta: 10 boxes');
  assert(mentioned === "P66 Customer Beta");

  const candidate = buildGovernedCandidate({
    contactId: "relay-contact",
    messageBody: 'Order for P66 Customer Beta: 10 boxes GST 29BBBBB1111B2Z2',
    senderIsStaffProxy: true,
  });

  assert(candidate.company_name === "P66 Customer Beta");
  assert(candidate.gst_number === "29BBBBB1111B2Z2");
  assert(candidate.company_id === undefined);
});

Deno.test("forwarded payload provenance is extracted without inferring customer", () => {
  const fields = extractPayloadIdentityFields({
    entry: [{
      changes: [{
        value: {
          messages: [{
            context: { forwarded: true, forwarded_from: "919800000001" },
            text: { body: "Forwarded message\nNeed order" },
          }],
        },
      }],
    }],
  });

  assert(fields.isForwarded === true);
  assert(fields.forwardedFromPhone === "919800000001");
  assert(fields.originalCommunicatorPhone === "919800000001");
  assert(fields.explicitCompanyId === null);
});

Deno.test("mapGovernedCustomerRow never returns company on non-resolved status", () => {
  const ambiguous = mapGovernedCustomerRow({
    company_id: "should-not-leak",
    business_name: "Collision Co",
    gst_number: null,
    payment_terms: null,
    is_frozen: false,
    resolution_status: "AMBIGUOUS",
    match_method: "MULTIPLE_NAME_MATCHES",
    confidence: 0.5,
    details: {},
  });
  assert(ambiguous.companyId === null);
  assert(ambiguous.resolutionStatus === "AMBIGUOUS");
});
