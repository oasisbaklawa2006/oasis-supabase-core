import {
  normalizeOperatorReplyProviderStatus,
  persistOperatorReplyProviderStatus,
  shouldAdvanceOperatorReplyStatus,
} from "./whatsappOperatorReplyStatus.ts";

type Row = Record<string, any>;

class FakeAdmin {
  events: Row[] = [];
  failEventInsert = false;
  tables: Record<string, Row[]> = {
    whatsapp_operator_reply_outbox: [],
  };

  async rpc(name: string, args: Record<string, unknown>) {
    if (name !== "persist_whatsapp_operator_reply_provider_status") {
      return { data: null, error: { message: "unexpected rpc" } };
    }

    const providerMessageId = String(args.p_provider_message_id ?? "");
    const targetStatus = String(args.p_status ?? "");
    const row = this.tables.whatsapp_operator_reply_outbox.find(
      (candidate) => candidate.provider_message_id === providerMessageId,
    );

    if (!row) {
      return { data: { matched: false, updated: false, status: null }, error: null };
    }

    const currentStatus = String(row.status ?? "");
    if (!shouldAdvanceOperatorReplyStatus(currentStatus, targetStatus)) {
      return { data: { matched: true, updated: false, status: currentStatus }, error: null };
    }

    if (this.failEventInsert) {
      return { data: null, error: { message: "event insert failed" } };
    }

    const now = new Date().toISOString();
    const next: Row = { ...row, status: targetStatus, updated_at: now };
    if (!next.accepted_at) next.accepted_at = now;
    if ((targetStatus === "DELIVERED" || targetStatus === "READ") && !next.delivered_at) {
      next.delivered_at = now;
    }
    if (targetStatus === "READ" && !next.read_at) next.read_at = now;

    this.events.push({
      reply_id: row.id,
      event_type: "PROVIDER_STATUS_CALLBACK",
      evidence: args.p_evidence,
    });
    Object.assign(row, next);

    return { data: { matched: true, updated: true, status: targetStatus }, error: null };
  }
}

Deno.test("provider status normalization is bounded to accepted/delivered/read", () => {
  if (normalizeOperatorReplyProviderStatus("sent") !== "ACCEPTED") throw new Error("sent");
  if (normalizeOperatorReplyProviderStatus("delivered") !== "DELIVERED") throw new Error("delivered");
  if (normalizeOperatorReplyProviderStatus("read") !== "READ") throw new Error("read");
  if (normalizeOperatorReplyProviderStatus("failed") !== null) throw new Error("failed must not mutate");
});

Deno.test("status advancement is monotonic", () => {
  if (!shouldAdvanceOperatorReplyStatus("ACCEPTED", "DELIVERED")) throw new Error("accepted->delivered");
  if (!shouldAdvanceOperatorReplyStatus("DELIVERED", "READ")) throw new Error("delivered->read");
  if (shouldAdvanceOperatorReplyStatus("READ", "DELIVERED")) throw new Error("must not downgrade");
  if (shouldAdvanceOperatorReplyStatus("READ", "READ")) throw new Error("duplicate must be no-op");
});

Deno.test("authenticated provider lifecycle persists sent then delivered then read", async () => {
  const admin = new FakeAdmin();
  admin.tables.whatsapp_operator_reply_outbox.push({
    id: "reply-1",
    provider_message_id: "wamid-1",
    status: "SENDING",
    accepted_at: null,
    delivered_at: null,
    read_at: null,
  });

  const sent = await persistOperatorReplyProviderStatus(admin as any, {
    status: "sent",
    providerMessageId: "wamid-1",
  });
  if (!sent.updated || sent.status !== "ACCEPTED") throw new Error("sent not persisted");

  const delivered = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered",
    providerMessageId: "wamid-1",
  });
  if (!delivered.updated || delivered.status !== "DELIVERED") throw new Error("delivery not persisted");

  const read = await persistOperatorReplyProviderStatus(admin as any, {
    status: "read",
    providerMessageId: "wamid-1",
  });
  if (!read.updated || read.status !== "READ") throw new Error("read not persisted");

  const row = admin.tables.whatsapp_operator_reply_outbox[0];
  if (!row.accepted_at || !row.delivered_at || !row.read_at) throw new Error("timestamps missing");
  if (admin.events.length !== 3) throw new Error("audit events missing");
});

Deno.test("duplicate and out-of-order callbacks are atomic no-ops", async () => {
  const admin = new FakeAdmin();
  admin.tables.whatsapp_operator_reply_outbox.push({
    id: "reply-2",
    provider_message_id: "wamid-2",
    status: "DELIVERED",
    accepted_at: "2026-09-27T00:00:00.000Z",
    delivered_at: "2026-09-27T00:01:00.000Z",
    read_at: null,
  });

  const duplicate = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered",
    providerMessageId: "wamid-2",
  });
  if (duplicate.updated || duplicate.status !== "DELIVERED") throw new Error("duplicate mutated state");

  const read = await persistOperatorReplyProviderStatus(admin as any, {
    status: "read",
    providerMessageId: "wamid-2",
  });
  if (!read.updated || read.status !== "READ") throw new Error("read not persisted");

  const stale = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered",
    providerMessageId: "wamid-2",
  });
  if (stale.updated || stale.status !== "READ") throw new Error("downgrade occurred");
  if (admin.events.length !== 1) throw new Error("no-op callbacks created duplicate evidence");
});

Deno.test("unknown provider message id is a no-op", async () => {
  const admin = new FakeAdmin();
  const result = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered",
    providerMessageId: "unknown",
  });
  if (result.matched || result.updated) throw new Error("unknown provider id mutated state");
});

Deno.test("rpc failure rolls back status acknowledgement", async () => {
  const admin = new FakeAdmin();
  admin.failEventInsert = true;
  admin.tables.whatsapp_operator_reply_outbox.push({
    id: "reply-3",
    provider_message_id: "wamid-3",
    status: "ACCEPTED",
    accepted_at: "2026-09-27T00:00:00.000Z",
    delivered_at: null,
    read_at: null,
  });

  let failed = false;
  try {
    await persistOperatorReplyProviderStatus(admin as any, {
      status: "delivered",
      providerMessageId: "wamid-3",
    });
  } catch (error) {
    failed = String(error).includes("WA_STATUS_RPC_FAILED");
  }

  if (!failed) throw new Error("rpc failure did not fail closed");
  if (admin.tables.whatsapp_operator_reply_outbox[0].status !== "ACCEPTED") {
    throw new Error("status advanced without atomic audit evidence");
  }
  if (admin.events.length !== 0) throw new Error("failed atomic write left audit evidence");
});
