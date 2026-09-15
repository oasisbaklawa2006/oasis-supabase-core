import {
  GOVERNED_REALTIME_CONTRACTS,
  POINT23_REALTIME_TRUTH_BOUNDARY,
  POINT23_RECONNECT_OWNERSHIP_BOUNDARY,
  RealtimeConsumerSession,
  RealtimeSessionDisposedError,
  SnapshotBeforeDeltaViolation,
  UnauthorizedRealtimeChannelError,
  assertAuthorizedRealtimeSubscription,
  buildScopedChannelName,
} from "./realtimeChannelContract.ts";

Deno.test("scoped channel names encode consumer, table, and scope", () => {
  const channel = buildScopedChannelName({
    consumerApplication: "Central",
    schema: "public",
    table: "whatsapp_inbound_messages",
    scope: "team-inbox",
  });
  if (channel !== "Central:public.whatsapp_inbound_messages:team-inbox") {
    throw new Error(`unexpected scoped channel name: ${channel}`);
  }
});

Deno.test("unauthorized-channel denial rejects uncontracted tables", () => {
  let threw = false;
  try {
    assertAuthorizedRealtimeSubscription({
      consumerApplication: "Central",
      schema: "public",
      table: "orders",
      scope: "team",
    });
  } catch (error) {
    threw = error instanceof UnauthorizedRealtimeChannelError;
  }
  if (!threw) {
    throw new Error("uncontracted table did not fail closed");
  }
});

Deno.test("unauthorized-channel denial rejects non-consumer applications", () => {
  let threw = false;
  try {
    assertAuthorizedRealtimeSubscription({
      consumerApplication: "Buyer App",
      schema: "public",
      table: "whatsapp_inbound_messages",
      scope: "team",
    });
  } catch (error) {
    threw = error instanceof UnauthorizedRealtimeChannelError;
  }
  if (!threw) {
    throw new Error("non-consumer application did not fail closed");
  }
});

Deno.test("snapshot-before-delta rejects deltas before authoritative snapshot load", () => {
  const session = new RealtimeConsumerSession({
    consumerApplication: "Central",
    schema: "public",
    table: "whatsapp_inbound_messages",
    scope: "team-inbox",
  });

  let threw = false;
  try {
    session.applyDelta({
      schema: "public",
      table: "whatsapp_inbound_messages",
      rowId: "row-1",
      eventType: "INSERT",
      version: "2026-09-07T10:00:00.000Z",
      payload: { id: "row-1" },
    });
  } catch (error) {
    threw = error instanceof SnapshotBeforeDeltaViolation &&
      (error as SnapshotBeforeDeltaViolation).message === POINT23_REALTIME_TRUTH_BOUNDARY;
  }
  if (!threw) {
    throw new Error("delta before snapshot did not fail closed");
  }
});

Deno.test("dedupe and version handling ignores duplicate row versions", () => {
  const session = new RealtimeConsumerSession({
    consumerApplication: "AI Studio",
    schema: "public",
    table: "whatsapp_operator_decisions",
    scope: "studio-inbox",
  });

  session.loadSnapshot([{ id: "row-1", version: "v1" }]);

  const first = session.applyDelta({
    schema: "public",
    table: "whatsapp_operator_decisions",
    rowId: "row-1",
    eventType: "UPDATE",
    version: "v2",
    payload: { id: "row-1" },
  });
  const duplicate = session.applyDelta({
    schema: "public",
    table: "whatsapp_operator_decisions",
    rowId: "row-1",
    eventType: "UPDATE",
    version: "v2",
    payload: { id: "row-1" },
  });

  if (first !== "applied" || duplicate !== "duplicate") {
    throw new Error("version dedupe did not classify applied vs duplicate correctly");
  }
});

Deno.test("unauthorized DELETE events are rejected without mutating session state", () => {
  const session = new RealtimeConsumerSession({
    consumerApplication: "Central",
    schema: "public",
    table: "whatsapp_sales_order_drafts",
    scope: "draft-refresh",
  });

  session.loadSnapshot([{ id: "draft-1", version: "v1" }]);

  const disposition = session.applyDelta({
    schema: "public",
    table: "whatsapp_sales_order_drafts",
    rowId: "draft-1",
    eventType: "DELETE",
    version: "v-delete",
    payload: { id: "draft-1" },
  });

  if (disposition !== "rejected_unauthorized_event") {
    throw new Error("DELETE event was not rejected for governed refresh-only tables");
  }
});

Deno.test("cleanup disposes session and blocks further deltas", () => {
  let cleaned = false;
  const session = new RealtimeConsumerSession({
    consumerApplication: "Central",
    schema: "public",
    table: "whatsapp_inbound_messages",
    scope: "team-inbox",
    onCleanup: () => {
      cleaned = true;
    },
  });

  session.loadSnapshot([{ id: "row-1", version: "v1" }]);
  session.dispose();

  if (!cleaned || !session.isDisposed) {
    throw new Error("dispose did not invoke cleanup callback");
  }

  let threw = false;
  try {
    session.applyDelta({
      schema: "public",
      table: "whatsapp_inbound_messages",
      rowId: "row-1",
      eventType: "UPDATE",
      version: "v2",
      payload: { id: "row-1" },
    });
  } catch (error) {
    threw = error instanceof RealtimeSessionDisposedError;
  }
  if (!threw) {
    throw new Error("delta after dispose did not fail closed");
  }
});

Deno.test("realtime-not-business-truth boundary requires authoritative refetch", () => {
  const session = new RealtimeConsumerSession({
    consumerApplication: "Central",
    schema: "public",
    table: "whatsapp_inbound_messages",
    scope: "team-inbox",
  });
  if (session.requiresAuthoritativeRefetch !== true) {
    throw new Error("session must require authoritative refetch after realtime hints");
  }
  if (!POINT23_REALTIME_TRUTH_BOUNDARY.includes("refresh hints")) {
    throw new Error("truth boundary wording drifted");
  }
  if (!POINT23_RECONNECT_OWNERSHIP_BOUNDARY.includes("Point24")) {
    throw new Error("reconnect ownership boundary wording drifted");
  }
});

Deno.test("governed contract allow-list remains exactly three WhatsApp inbox tables", () => {
  if (GOVERNED_REALTIME_CONTRACTS.length !== 3) {
    throw new Error(`expected 3 governed contracts, found ${GOVERNED_REALTIME_CONTRACTS.length}`);
  }
  const tables = GOVERNED_REALTIME_CONTRACTS.map((contract) => contract.table).sort();
  const expected = [
    "whatsapp_inbound_messages",
    "whatsapp_operator_decisions",
    "whatsapp_sales_order_drafts",
  ].sort();
  if (tables.join(",") !== expected.join(",")) {
    throw new Error(`governed table allow-list drifted: ${tables.join(",")}`);
  }
});
