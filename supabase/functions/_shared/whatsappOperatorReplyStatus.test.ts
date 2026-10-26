import {
  normalizeOperatorReplyProviderStatus,
  persistOperatorReplyProviderStatus,
  persistOperatorReplyProviderStatusBatch,
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
  if (normalizeOperatorReplyProviderStatus("failed") !== "FAILED_FINAL") throw new Error("failed status dropped");
  if (normalizeOperatorReplyProviderStatus("undelivered") !== "FAILED_FINAL") throw new Error("undelivered status dropped");
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

Deno.test("provider failed callback is terminal with a sanitized error code and one event", async () => {
  const admin = new FakeAdmin();
  admin.tables.whatsapp_operator_reply_outbox.push({
    id: "reply-failure", provider_message_id: "wamid-failed", status: "ACCEPTED",
    delivered_at: null, read_at: null, last_error_code: null,
  });
  const failed = await persistOperatorReplyProviderStatus(admin as any, {
    status: "failed", providerMessageId: "wamid-failed", providerErrorCode: "ERR 131026 (secret?)",
  });
  if (!failed.updated || failed.status !== "FAILED_FINAL") throw new Error("failure not persisted");
  if (admin.events.length !== 1) throw new Error("failure event missing");
  if (admin.events[0].evidence.provider_error_code !== "ERR131026secret") throw new Error("raw provider error was leaked");
  const duplicate = await persistOperatorReplyProviderStatus(admin as any, {
    status: "failed", providerMessageId: "wamid-failed",
  });
  if (duplicate.updated || admin.events.length !== 1) throw new Error("duplicate failure mutated");
  const late = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered", providerMessageId: "wamid-failed",
  });
  if (late.updated) throw new Error("terminal failure was resurrected");
});
Deno.test("a delayed failed callback never downgrades a verified delivery or read", async () => {
  for (const state of ["DELIVERED", "READ"]) {
    const admin = new FakeAdmin();
    admin.tables.whatsapp_operator_reply_outbox.push({
      id: state, provider_message_id: "wamid-" + state, status: state,
    });
    const r = await persistOperatorReplyProviderStatus(admin as any, {
      status: "failed", providerMessageId: "wamid-" + state, providerErrorCode: 131026,
    });
    if (r.updated || r.status !== state || admin.events.length) throw new Error(state + " regressed");
  }
});
Deno.test("a recognized status lacking provider id fails closed", async () => {
  let caught = false;
  try {
    await persistOperatorReplyProviderStatus(new FakeAdmin() as any, {
      status: "failed", providerMessageId: null,
    });
  } catch (e) {
    caught = String(e).includes("WA_STATUS_PROVIDER_ID_MISSING");
  }
  if (!caught) throw new Error("missing provider ID was silently acknowledged");
});

Deno.test("batched delivery callbacks persist every status, and repeat is idempotent", async () => {
  const admin = new FakeAdmin();
  admin.tables.whatsapp_operator_reply_outbox.push(
    { id: "one", provider_message_id: "wamid.one", status: "ACCEPTED" },
    { id: "two", provider_message_id: "wamid.two", status: "ACCEPTED" },
  );
  const batch = [
    { status: "delivered", providerMessageId: "wamid.one" },
    { status: "failed", providerMessageId: "wamid.two", providerErrorCode: 131026 },
  ];
  const first = await persistOperatorReplyProviderStatusBatch(admin as any, batch);
  if (first.count !== 2 || first.updated !== 2 || admin.events.length !== 2) {
    throw new Error("batch did not persist all callbacks");
  }
  const repeated = await persistOperatorReplyProviderStatusBatch(admin as any, batch);
  if (repeated.count !== 2 || repeated.updated !== 0 || admin.events.length !== 2) {
    throw new Error("duplicate callbacks changed state or evidence");
  }
});
Deno.test("partial batch failure fails closed and safe replay resumes without duplicate events", async () => {
  const admin = new FakeAdmin();
  admin.tables.whatsapp_operator_reply_outbox.push(
    { id: "one", provider_message_id: "wamid.one", status: "ACCEPTED" },
    { id: "two", provider_message_id: "wamid.two", status: "ACCEPTED" },
  );
  const batch = [
    { status: "delivered", providerMessageId: "wamid.one" },
    { status: "read", providerMessageId: "wamid.two" },
  ];
  const originalRpc = admin.rpc.bind(admin);
  let failOnce = true;
  admin.rpc = async (name, args) => {
    if (args.p_provider_message_id === "wamid.two" && failOnce) {
      failOnce = false;
      return { data: null, error: { message: "transient" } };
    }
    return originalRpc(name, args);
  };
  let rejected = false;
  try {
    await persistOperatorReplyProviderStatusBatch(admin as any, batch);
  } catch (e) { rejected = String(e).includes("WA_STATUS_RPC_FAILED"); }
  if (!rejected || admin.events.length !== 1) throw new Error("partial failure incorrectly acknowledged");
  const recovered = await persistOperatorReplyProviderStatusBatch(admin as any, batch);
  if (recovered.updated !== 1 || admin.events.length !== 2) {
    throw new Error("replay did not resume idempotently");
  }
});
