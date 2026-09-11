import { runDisposableConsumerReconnectReplayProbe } from "./disposableConsumerFixture.ts";

const TABLE = "whatsapp_inbound_messages";
const ROW = "point23-fixture-row-1";

Deno.test("Central disposable fixture reconnect reloads snapshot and dedupes replay", () => {
  const result = runDisposableConsumerReconnectReplayProbe({
    consumerApplication: "Central",
    table: TABLE,
    scope: "team-inbox",
    initialSnapshot: [{ id: ROW, version: "v1" }],
    preDisconnectEvents: [{
      schema: "public",
      table: TABLE,
      rowId: ROW,
      version: "v2",
      eventType: "UPDATE",
      payload: { id: ROW },
    }],
    postReconnectSnapshot: [{ id: ROW, version: "v2" }],
    replayedEvents: [{
      schema: "public",
      table: TABLE,
      rowId: ROW,
      version: "v2",
      eventType: "UPDATE",
      payload: { id: ROW },
    }],
    newLiveEvents: [{
      schema: "public",
      table: TABLE,
      rowId: ROW,
      version: "v3",
      eventType: "UPDATE",
      payload: { id: ROW },
    }],
  });

  if (!result.cleanupInvoked || !result.reconnectCompleted) {
    throw new Error("Central reconnect probe did not complete cleanup/reconnect");
  }
  if (result.channelName !== "Central:public.whatsapp_inbound_messages:team-inbox") {
    throw new Error(`unexpected Central channel: ${result.channelName}`);
  }
  if (result.firstPassApplied !== 1 || result.replayDuplicates !== 1 || result.postReconnectApplied !== 1) {
    throw new Error(`Central replay counts wrong: ${JSON.stringify(result)}`);
  }
});

Deno.test("AI Studio disposable fixture reconnect reloads snapshot and dedupes replay", () => {
  const result = runDisposableConsumerReconnectReplayProbe({
    consumerApplication: "AI Studio",
    table: "whatsapp_operator_decisions",
    scope: "studio-inbox",
    initialSnapshot: [{ id: "decision-1", version: "v1" }],
    preDisconnectEvents: [{
      schema: "public",
      table: "whatsapp_operator_decisions",
      rowId: "decision-1",
      version: "v2",
      eventType: "UPDATE",
      payload: { id: "decision-1" },
    }],
    postReconnectSnapshot: [{ id: "decision-1", version: "v2" }],
    replayedEvents: [{
      schema: "public",
      table: "whatsapp_operator_decisions",
      rowId: "decision-1",
      version: "v2",
      eventType: "UPDATE",
      payload: { id: "decision-1" },
    }],
    newLiveEvents: [{
      schema: "public",
      table: "whatsapp_operator_decisions",
      rowId: "decision-1",
      version: "v3",
      eventType: "UPDATE",
      payload: { id: "decision-1" },
    }],
  });

  if (result.consumerApplication !== "AI Studio") {
    throw new Error("AI Studio fixture mislabeled");
  }
  if (result.replayDuplicates !== 1 || result.postReconnectApplied !== 1) {
    throw new Error(`AI Studio replay counts wrong: ${JSON.stringify(result)}`);
  }
});

Deno.test("disposable fixtures keep Central and AI Studio channel scopes isolated", () => {
  const central = runDisposableConsumerReconnectReplayProbe({
    consumerApplication: "Central",
    table: TABLE,
    scope: "team-inbox",
    initialSnapshot: [],
    preDisconnectEvents: [],
    postReconnectSnapshot: [],
    replayedEvents: [],
    newLiveEvents: [],
  });
  const studio = runDisposableConsumerReconnectReplayProbe({
    consumerApplication: "AI Studio",
    table: TABLE,
    scope: "studio-inbox",
    initialSnapshot: [],
    preDisconnectEvents: [],
    postReconnectSnapshot: [],
    replayedEvents: [],
    newLiveEvents: [],
  });
  if (central.channelName === studio.channelName) {
    throw new Error("consumer channel scopes must not collide");
  }
});
