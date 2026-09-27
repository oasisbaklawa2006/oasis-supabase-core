import {
  normalizeProviderReplyStatus,
  persistOperatorReplyProviderStatus,
} from "./whatsappOperatorReplyStatus.ts";

function adminReturning(data: unknown, error: { message: string } | null = null) {
  return {
    rpc: (_name: string, _args: Record<string, unknown>) =>
      Promise.resolve({ data, error }),
  } as any;
}

Deno.test("normalizes sent/accepted/delivered/read monotonically", () => {
  if (normalizeProviderReplyStatus("sent") !== "ACCEPTED") throw new Error("sent");
  if (normalizeProviderReplyStatus("accepted") !== "ACCEPTED") throw new Error("accepted");
  if (normalizeProviderReplyStatus("delivered") !== "DELIVERED") throw new Error("delivered");
  if (normalizeProviderReplyStatus("read") !== "READ") throw new Error("read");
  if (normalizeProviderReplyStatus("failed") !== null) throw new Error("unsupported");
});

Deno.test("persists delivered callback through governed lifecycle RPC", async () => {
  let rpcName = "";
  let rpcArgs: Record<string, unknown> = {};
  const admin = {
    rpc: (name: string, args: Record<string, unknown>) => {
      rpcName = name;
      rpcArgs = args;
      return Promise.resolve({ data: { id: "reply-1" }, error: null });
    },
  } as any;

  const result = await persistOperatorReplyProviderStatus(
    admin,
    { status: "delivered", providerMessageId: "wamid-1" },
    "click2api",
  );
  if (!result.ok || !result.matched || result.normalizedStatus !== "DELIVERED") {
    throw new Error("delivery not persisted");
  }
  if (rpcName !== "record_whatsapp_operator_reply_status") {
    throw new Error("wrong rpc");
  }
  if (
    rpcArgs.p_reply_id !== null ||
    rpcArgs.p_provider !== "click2api" ||
    rpcArgs.p_provider_message_id !== "wamid-1" ||
    rpcArgs.p_status !== "DELIVERED"
  ) {
    throw new Error("wrong rpc args");
  }
});

Deno.test("missing provider message id is acknowledged without mutation", async () => {
  let calls = 0;
  const admin = {
    rpc: () => {
      calls += 1;
      return Promise.resolve({ data: null, error: null });
    },
  } as any;
  const result = await persistOperatorReplyProviderStatus(
    admin,
    { status: "read", providerMessageId: null },
    "click2api",
  );
  if (!result.ok || result.code !== "PROVIDER_MESSAGE_ID_MISSING" || calls !== 0) {
    throw new Error("missing id must not mutate");
  }
});

Deno.test("unknown or stale provider id does not trigger endless provider retry", async () => {
  const result = await persistOperatorReplyProviderStatus(
    adminReturning(null, { message: "WA5_STATUS_BOUNDARY_OR_REGRESSION" }),
    { status: "delivered", providerMessageId: "unknown" },
    "click2api",
  );
  if (!result.ok || result.matched || result.code !== "NOT_MATCHED_OR_STALE") {
    throw new Error("boundary handling");
  }
});

Deno.test("database persistence failures fail closed for provider retry", async () => {
  const result = await persistOperatorReplyProviderStatus(
    adminReturning(null, { message: "connection unavailable" }),
    { status: "read", providerMessageId: "wamid-2" },
    "click2api",
  );
  if (result.ok || result.code !== "STATUS_PERSISTENCE_FAILED") {
    throw new Error("db failure must fail closed");
  }
});
