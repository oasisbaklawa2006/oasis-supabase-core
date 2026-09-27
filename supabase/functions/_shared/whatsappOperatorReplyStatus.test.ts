import {
  normalizeOperatorReplyProviderStatus,
  persistOperatorReplyProviderStatus,
  shouldAdvanceOperatorReplyStatus,
} from "./whatsappOperatorReplyStatus.ts";

type Row = Record<string, any>;

class FakeBuilder implements PromiseLike<any> {
  filters: [string, unknown][] = [];
  selected = "";
  updatePatch: Row | null = null;

  constructor(
    private readonly admin: FakeAdmin,
    private readonly table: string,
  ) {}

  select(columns: string) {
    this.selected = columns;
    return this;
  }

  eq(column: string, value: unknown) {
    this.filters.push([column, value]);
    return this;
  }

  update(patch: Row) {
    this.updatePatch = patch;
    return this;
  }

  insert(row: Row) {
    if (this.table === "whatsapp_operator_reply_events") {
      if (this.admin.failEventInsert) {
        return Promise.resolve({ data: null, error: { message: "event insert failed" } });
      }
      this.admin.events.push({ ...row });
      return Promise.resolve({ data: row, error: null });
    }
    throw new Error("unexpected insert");
  }

  async maybeSingle() {
    const rows = this.admin.tables[this.table] ?? [];
    const row = rows.find((candidate) =>
      this.filters.every(([column, value]) => candidate[column] === value)
    );
    if (!row) return { data: null, error: null };

    if (this.updatePatch) Object.assign(row, this.updatePatch);
    return { data: { ...row }, error: null };
  }

  then<TResult1 = any, TResult2 = never>(
    onfulfilled?: ((value: any) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: any) => TResult2 | PromiseLike<TResult2>) | null,
  ): PromiseLike<TResult1 | TResult2> {
    return this.maybeSingle().then(onfulfilled, onrejected);
  }
}

class FakeAdmin {
  events: Row[] = [];
  failEventInsert = false;
  tables: Record<string, Row[]> = {
    whatsapp_operator_reply_outbox: [],
  };

  from(table: string) {
    return new FakeBuilder(this, table);
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

Deno.test("out-of-order callback cannot downgrade READ", async () => {
  const admin = new FakeAdmin();
  admin.tables.whatsapp_operator_reply_outbox.push({
    id: "reply-2",
    provider_message_id: "wamid-2",
    status: "READ",
    accepted_at: "2026-09-27T00:00:00.000Z",
    delivered_at: "2026-09-27T00:01:00.000Z",
    read_at: "2026-09-27T00:02:00.000Z",
  });
  const result = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered",
    providerMessageId: "wamid-2",
  });
  if (result.updated || result.status !== "READ") throw new Error("downgrade occurred");
  if (admin.events.length !== 0) throw new Error("no-op callback should not add transition event");
});

Deno.test("unknown provider message id is a no-op", async () => {
  const admin = new FakeAdmin();
  const result = await persistOperatorReplyProviderStatus(admin as any, {
    status: "delivered",
    providerMessageId: "unknown",
  });
  if (result.matched || result.updated) throw new Error("unknown provider id mutated state");
});

Deno.test("audit event failure fails closed before status acknowledgement", async () => {
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
    failed = String(error).includes("WA_STATUS_EVENT_WRITE_FAILED");
  }
  if (!failed) throw new Error("event failure did not fail closed");
  if (admin.tables.whatsapp_operator_reply_outbox[0].status !== "ACCEPTED") {
    throw new Error("status advanced without audit evidence");
  }
});
