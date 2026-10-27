import { verifyChallengeToken, verifyMetaSignature } from "./whatsappWebhookSecurity.ts";

export type WebhookStatusEvent = {
  status: string;
  providerMessageId: string | null;
  providerErrorCode?: string | number | null;
};

/** Bounded reason codes for provider status elements skipped during decode (no PII). */
export type StatusElementQuarantineReason =
  | "non_object"
  | "missing_status"
  | "invalid_status_type"
  | "status_oversized"
  | "provider_id_oversized";

export type StatusElementQuarantine = {
  reason: StatusElementQuarantineReason;
};

export type WebhookStatusParseResult = {
  events: WebhookStatusEvent[];
  quarantined: StatusElementQuarantine[];
};

export type WebhookBoundaryResult =
  | { ok: false; status: 400 | 401 | 403 | 500; code: string }
  | {
    ok: true;
    payload: any;
    statusEvent: WebhookStatusEvent | null;
    statusEvents: WebhookStatusEvent[];
    statusQuarantined: StatusElementQuarantine[];
  };

const MAX_STATUS_STRING_LEN = 64;
const MAX_PROVIDER_ID_LEN = 128;
const MAX_QUARANTINE_DIAGNOSTICS = 16;

const asRecord = (value: unknown): Record<string, any> | null =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : null;

const boundedErrorCode = (value: unknown): string | null => {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const code = String(value).replace(/[^a-zA-Z0-9_.:-]/g, "").slice(0, 64);
  return code || null;
};

const pushQuarantine = (
  quarantined: StatusElementQuarantine[],
  reason: StatusElementQuarantineReason,
) => {
  if (quarantined.length < MAX_QUARANTINE_DIAGNOSTICS) {
    quarantined.push({ reason });
  }
};

/** Decode Meta statuses; malformed members are quarantined instead of aborting the batch. */
export function detectWebhookStatusEventsWithQuarantine(payload: any): WebhookStatusParseResult {
  const events: WebhookStatusEvent[] = [];
  const quarantined: StatusElementQuarantine[] = [];
  if (Array.isArray(payload?.entry)) {
    for (const rawEntry of payload.entry) {
      const entry = asRecord(rawEntry);
      if (!Array.isArray(entry?.changes)) continue;
      for (const rawChange of entry.changes) {
        const change = asRecord(rawChange);
        const statuses = change?.value?.statuses;
        if (!Array.isArray(statuses)) continue;
        for (const rawStatus of statuses) {
          const event = asRecord(rawStatus);
          if (!event) {
            pushQuarantine(quarantined, "non_object");
            continue;
          }
          if (typeof event.id === "string" && event.id.length > MAX_PROVIDER_ID_LEN) {
            pushQuarantine(quarantined, "provider_id_oversized");
            continue;
          }
          if (typeof event.status !== "string") {
            pushQuarantine(
              quarantined,
              event.status === undefined || event.status === null ? "missing_status" : "invalid_status_type",
            );
            continue;
          }
          if (event.status.length > MAX_STATUS_STRING_LEN) {
            pushQuarantine(quarantined, "status_oversized");
            continue;
          }
          events.push({
            status: event.status,
            providerMessageId: typeof event.id === "string" ? event.id : null,
            providerErrorCode: boundedErrorCode(event.errors?.[0]?.code),
          });
        }
      }
    }
  }
  if (events.length) return { events, quarantined };
  // Click2API's dedicated status payload; never infer an ID from queue_id.
  const click2apiStatus = payload?.message?.message_status;
  if (typeof click2apiStatus !== "string") return { events, quarantined };
  const id = payload?.response?.messages?.[0]?.id;
  return {
    events: [{
      status: click2apiStatus,
      providerMessageId: typeof id === "string" ? id : null,
      providerErrorCode: boundedErrorCode(payload?.message?.error_code),
    }],
    quarantined,
  };
}

/** Decode all Meta statuses, preserving provider order and per-message association. */
export function detectWebhookStatusEvents(payload: any): WebhookStatusEvent[] {
  return detectWebhookStatusEventsWithQuarantine(payload).events;
}

/** Backward-compatible single-event reader for existing callers/tests. */
export function detectWebhookStatusEvent(payload: any): WebhookStatusEvent | null {
  return detectWebhookStatusEvents(payload)[0] ?? null;
}

export async function authenticateAndParseWebhook(args: {
  rawBody: Uint8Array;
  requestUrl: string;
  signatureHeader: string | null;
  verifyToken: string | undefined;
  appSecret: string | undefined;
}): Promise<WebhookBoundaryResult> {
  const url = new URL(args.requestUrl);
  const source = url.searchParams.get("source");
  const authResult = source === "click2api"
    ? verifyChallengeToken(url.searchParams.get("token"), args.verifyToken)
    : await verifyMetaSignature(args.rawBody, args.signatureHeader, args.appSecret);
  if (!authResult.ok) return authResult;
  let payload: any;
  try {
    payload = JSON.parse(new TextDecoder().decode(args.rawBody));
  } catch {
    return { ok: false, status: 400, code: "invalid_json" };
  }
  const { events: statusEvents, quarantined: statusQuarantined } = detectWebhookStatusEventsWithQuarantine(payload);
  return { ok: true, payload, statusEvent: statusEvents[0] ?? null, statusEvents, statusQuarantined };
}
