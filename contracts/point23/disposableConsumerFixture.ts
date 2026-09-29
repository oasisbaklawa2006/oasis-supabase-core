import {
  RealtimeConsumerSession,
  type RealtimeDeltaEvent,
  type RealtimeDeltaDisposition,
} from "./realtimeChannelContract.ts";

export type DisposableConsumerApplication = "Central" | "AI Studio";

export type DisposableSnapshotRow = { id: string; version: string };

export type DisposableReplayEvent = {
  schema: string;
  table: string;
  rowId: string;
  version: string;
  eventType: "INSERT" | "UPDATE";
  payload: unknown;
};

export type DisposableReconnectReplayResult = {
  consumerApplication: DisposableConsumerApplication;
  channelName: string;
  firstPassApplied: number;
  replayDuplicates: number;
  postReconnectApplied: number;
  cleanupInvoked: boolean;
  reconnectCompleted: boolean;
};

/** Disposable Central / AI Studio fixture: disconnect, snapshot reload, replay dedupe. */
export function runDisposableConsumerReconnectReplayProbe(options: {
  consumerApplication: DisposableConsumerApplication;
  table: string;
  scope: string;
  initialSnapshot: readonly DisposableSnapshotRow[];
  preDisconnectEvents: readonly DisposableReplayEvent[];
  postReconnectSnapshot: readonly DisposableSnapshotRow[];
  replayedEvents: readonly DisposableReplayEvent[];
  newLiveEvents: readonly DisposableReplayEvent[];
}): DisposableReconnectReplayResult {
  let cleanupInvoked = false;
  const session = new RealtimeConsumerSession({
    consumerApplication: options.consumerApplication,
    schema: "public",
    table: options.table,
    scope: options.scope,
    onCleanup: () => {
      cleanupInvoked = true;
    },
  });

  session.loadSnapshot(options.initialSnapshot);

  let firstPassApplied = 0;
  for (const event of options.preDisconnectEvents) {
    if (apply(session, event) === "applied") {
      firstPassApplied += 1;
    }
  }

  const channelName = session.channelName;
  session.dispose();

  const reconnected = new RealtimeConsumerSession({
    consumerApplication: options.consumerApplication,
    schema: "public",
    table: options.table,
    scope: options.scope,
  });
  reconnected.loadSnapshot(options.postReconnectSnapshot);

  let replayDuplicates = 0;
  let postReconnectApplied = 0;
  for (const event of options.replayedEvents) {
    const disposition = apply(reconnected, event);
    if (disposition === "duplicate") replayDuplicates += 1;
    if (disposition === "applied") postReconnectApplied += 1;
  }
  for (const event of options.newLiveEvents) {
    if (apply(reconnected, event) === "applied") {
      postReconnectApplied += 1;
    }
  }

  reconnected.dispose();

  return {
    consumerApplication: options.consumerApplication,
    channelName,
    firstPassApplied,
    replayDuplicates,
    postReconnectApplied,
    cleanupInvoked,
    reconnectCompleted: true,
  };
}

function apply(
  session: RealtimeConsumerSession,
  event: DisposableReplayEvent,
): RealtimeDeltaDisposition {
  return session.applyDelta({
    schema: event.schema,
    table: event.table,
    rowId: event.rowId,
    eventType: event.eventType,
    version: event.version,
    payload: event.payload,
  });
}
