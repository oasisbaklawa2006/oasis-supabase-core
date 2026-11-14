import { processErpInboundRow } from "./processErpInboundRow.ts";
import type { ErpWhatsAppMessageRow } from "./types.ts";

const baseline: ErpWhatsAppMessageRow = {
  id: "test-erp-message-001",
  contact_id: "test-contact-001",
  direction: "inbound",
  message_type: "text",
  content: "one carton of sweets",
  provider_message_id: "test-provider-001",
  provider: "test-provider",
  status: "received",
  message_timestamp: "2026-11-07T12:00:00Z",
  created_at: "2026-11-07T12:00:00Z",
  whatsapp_contacts: {
    phone_number: "+911234567890",
    customer_name: "Synthetic Sender",
  },
};

Deno.test("ERP mapping skip variants make zero resolver and ingest calls", async () => {
  const calls = { resolver: 0, rpc: 0 };
  const deps = {
    resolve: async (_messageBody: string) => {
      calls.resolver += 1;
      return { resolver_status: "resolved" as const, resolver_result_json: null };
    },
    rpc: async (_fn: string, _args: Record<string, unknown>) => {
      calls.rpc += 1;
      return { data: null, error: null };
    },
  };

  const skippedRows: ErpWhatsAppMessageRow[] = [
    { ...baseline, direction: "outbound" },
    { ...baseline, message_type: "image" },
    { ...baseline, content: "   " },
  ];

  for (const row of skippedRows) {
    const result = await processErpInboundRow(row, deps);
    if (!result.ok || !("skipped" in result) || result.skipped !== true) {
      throw new Error("ERP skipped row must return ok=true, skipped=true");
    }
  }
  if (calls.resolver !== 0 || calls.rpc !== 0) {
    throw new Error("ERP skipped rows must never invoke resolver or ingest RPC");
  }
});

Deno.test("ERP valid inbound row still calls resolver and ingest once", async () => {
  let resolverCalls = 0;
  let ingestCalls = 0;
  let observedResolverMessage: string | undefined;
  const result = await processErpInboundRow(baseline, {
    resolve: async (messageBody) => {
      resolverCalls += 1;
      observedResolverMessage = messageBody;
      return { resolver_status: "resolved", resolver_result_json: null };
    },
    rpc: async (fn, args) => {
      ingestCalls += 1;
      if (fn !== "ingest_whatsapp_inbound_message" || args._message_body !== baseline.content) {
        throw new Error("Wrong governed ingest RPC arguments");
      }
      return { data: { id: "synthetic-ingest-id", resolver_status: "resolved" }, error: null };
    },
  });

  if (!result.ok || ("skipped" in result && result.skipped)) {
    throw new Error("Valid inbound ERP row must be ingested, not skipped");
  }
  if (resolverCalls !== 1 || ingestCalls !== 1) {
    throw new Error("Valid inbound ERP row must use resolver and ingest exactly once");
  }
  if (observedResolverMessage !== baseline.content) {
    throw new Error("Wrong ERP message passed to resolver");
  }
});


Deno.test("ERP inbound row without sender fails before resolving or ingesting", async () => {
  const calls = { resolver: 0, rpc: 0 };
  const result = await processErpInboundRow(
    { ...baseline, whatsapp_contacts: null },
    {
      resolve: async () => {
        calls.resolver += 1;
        return { resolver_status: "resolved", resolver_result_json: null };
      },
      rpc: async () => {
        calls.rpc += 1;
        return { data: { id: "unexpected-ingest-id" }, error: null };
      },
    },
  );

  if (result.ok || result.error !== "sender_phone is required") {
    throw new Error("Missing sender must return the governed mapping error");
  }
  if (calls.resolver !== 0 || calls.rpc !== 0) {
    throw new Error("Invalid ERP inbound rows must not resolve or ingest");
  }
});
