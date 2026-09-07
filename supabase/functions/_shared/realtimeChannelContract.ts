/**
 * Point 23 — shared realtime-channel standards contract.
 *
 * Core-owned validation surface for Postgres Changes consumers (Central, AI Studio).
 * Transport reconnect/backoff remains Point24 consumer responsibility.
 * Business truth remains in Postgres/RLS — realtime events are refresh hints only.
 */

export const POINT23_REALTIME_TRUTH_BOUNDARY =
  "Realtime postgres_changes are refresh hints only; consumers must re-fetch authoritative state before acting.";

export const POINT23_RECONNECT_OWNERSHIP_BOUNDARY =
  "Transport reconnect and backoff are consumer-owned (Point24); this contract governs channel scope, snapshot-before-delta, dedupe, and cleanup only.";

export type GovernedRealtimeContract = {
  schema: string;
  table: string;
  owningApplication: string;
  consumers: readonly string[];
  eventTypes: readonly ("INSERT" | "UPDATE" | "DELETE")[];
};

/** Frozen allow-list aligned with public.realtime_subscription_contracts on Core main. */
export const GOVERNED_REALTIME_CONTRACTS: readonly GovernedRealtimeContract[] = [
  {
    schema: "public",
    table: "whatsapp_inbound_messages",
    owningApplication: "Central",
    consumers: ["Central", "AI Studio"],
    eventTypes: ["INSERT", "UPDATE"],
  },
  {
    schema: "public",
    table: "whatsapp_operator_decisions",
    owningApplication: "Central",
    consumers: ["Central", "AI Studio"],
    eventTypes: ["INSERT", "UPDATE"],
  },
  {
    schema: "public",
    table: "whatsapp_sales_order_drafts",
    owningApplication: "Central",
    consumers: ["Central", "AI Studio"],
    eventTypes: ["INSERT", "UPDATE"],
  },
] as const;

export type RealtimeChannelScope = {
  consumerApplication: string;
  schema: string;
  table: string;
  scope: string;
};

export type RealtimeDeltaEvent = {
  schema: string;
  table: string;
  rowId: string;
  eventType: "INSERT" | "UPDATE" | "DELETE";
  /** Monotonic row version — typically updated_at ISO string or commit ordering key. */
  version: string;
  payload: unknown;
};

export type RealtimeDeltaDisposition = "applied" | "duplicate" | "rejected_unauthorized_event";

export class UnauthorizedRealtimeChannelError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "UnauthorizedRealtimeChannelError";
  }
}

export class SnapshotBeforeDeltaViolation extends Error {
  constructor(message: string) {
    super(message);
    this.name = "SnapshotBeforeDeltaViolation";
  }
}

export class RealtimeSessionDisposedError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "RealtimeSessionDisposedError";
  }
}

export function findGovernedRealtimeContract(
  schema: string,
  table: string,
): GovernedRealtimeContract | undefined {
  return GOVERNED_REALTIME_CONTRACTS.find(
    (contract) => contract.schema === schema && contract.table === table,
  );
}

/** Scoped channel naming: {consumer}:{schema}.{table}:{scope} */
export function buildScopedChannelName(scope: RealtimeChannelScope): string {
  const consumer = scope.consumerApplication.trim();
  const channelScope = scope.scope.trim();
  if (!consumer || !channelScope) {
    throw new Error("consumerApplication and scope are required for scoped channels");
  }
  return `${consumer}:${scope.schema}.${scope.table}:${channelScope}`;
}

export function assertAuthorizedRealtimeSubscription(scope: RealtimeChannelScope): GovernedRealtimeContract {
  const contract = findGovernedRealtimeContract(scope.schema, scope.table);
  if (!contract) {
    throw new UnauthorizedRealtimeChannelError(
      `unauthorized realtime channel: ${scope.schema}.${scope.table} is not allow-listed`,
    );
  }
  if (!contract.consumers.includes(scope.consumerApplication)) {
    throw new UnauthorizedRealtimeChannelError(
      `unauthorized realtime channel: ${scope.consumerApplication} cannot subscribe to ${scope.schema}.${scope.table}`,
    );
  }
  return contract;
}

export function assertAuthorizedRealtimeEvent(
  contract: GovernedRealtimeContract,
  event: RealtimeDeltaEvent,
): void {
  if (event.schema !== contract.schema || event.table !== contract.table) {
    throw new UnauthorizedRealtimeChannelError(
      `unauthorized realtime event: ${event.schema}.${event.table} does not match subscription contract`,
    );
  }
  if (!contract.eventTypes.includes(event.eventType)) {
    throw new UnauthorizedRealtimeChannelError(
      `unauthorized realtime event: ${event.eventType} is not published for ${contract.schema}.${contract.table}`,
    );
  }
}

function rowVersionKey(event: RealtimeDeltaEvent): string {
  return `${event.schema}.${event.table}:${event.rowId}`;
}

export type RealtimeConsumerSessionOptions = RealtimeChannelScope & {
  onCleanup?: (channelName: string) => void;
};

/**
 * Enforces snapshot-before-delta, version dedupe, scoped channel identity, and cleanup.
 * Does not implement transport reconnect/backoff (Point24 boundary).
 */
export class RealtimeConsumerSession {
  readonly channelName: string;
  readonly contract: GovernedRealtimeContract;

  private snapshotLoaded = false;
  private disposed = false;
  private readonly seenVersions = new Map<string, string>();
  private readonly onCleanup?: (channelName: string) => void;

  constructor(options: RealtimeConsumerSessionOptions) {
    this.contract = assertAuthorizedRealtimeSubscription(options);
    this.channelName = buildScopedChannelName(options);
    this.onCleanup = options.onCleanup;
  }

  get requiresAuthoritativeRefetch(): true {
    return true;
  }

  loadSnapshot(rows: ReadonlyArray<{ id: string; version: string }>): void {
    if (this.disposed) {
      throw new RealtimeSessionDisposedError("cannot load snapshot on disposed realtime session");
    }
    this.seenVersions.clear();
    for (const row of rows) {
      this.seenVersions.set(`${this.contract.schema}.${this.contract.table}:${row.id}`, row.version);
    }
    this.snapshotLoaded = true;
  }

  applyDelta(event: RealtimeDeltaEvent): RealtimeDeltaDisposition {
    if (this.disposed) {
      throw new RealtimeSessionDisposedError("cannot apply delta on disposed realtime session");
    }
    if (!this.snapshotLoaded) {
      throw new SnapshotBeforeDeltaViolation(
        POINT23_REALTIME_TRUTH_BOUNDARY,
      );
    }

    if (!contractEventTypesInclude(this.contract, event.eventType)) {
      return "rejected_unauthorized_event";
    }

    const key = rowVersionKey(event);
    const previous = this.seenVersions.get(key);
    if (previous === event.version) {
      return "duplicate";
    }

    this.seenVersions.set(key, event.version);
    return "applied";
  }

  dispose(): void {
    if (this.disposed) return;
    this.disposed = true;
    this.seenVersions.clear();
    this.snapshotLoaded = false;
    this.onCleanup?.(this.channelName);
  }

  get isDisposed(): boolean {
    return this.disposed;
  }
}

function contractEventTypesInclude(
  contract: GovernedRealtimeContract,
  eventType: RealtimeDeltaEvent["eventType"],
): boolean {
  return contract.eventTypes.includes(eventType);
}
