import { verifyChallengeToken, verifyMetaSignature } from "./whatsappWebhookSecurity.ts";

export type WebhookStatusEvent = {
  status: string;
  providerMessageId: string | null;
  providerErrorCode?: string | number | null;
};

export type WebhookBoundaryResult =
  | { ok: false; status: 400 | 401 | 403 | 500; code: string }
  | { ok: true; payload: any; statusEvent: WebhookStatusEvent | null; statusEvents: WebhookStatusEvent[] };

const asRecord = (value: unknown): Record<string, any> | null =>
  value && typeof value === "object" && !Array.isArray(value) ? value as Record<string, any> : null;

const boundedErrorCode = (value: unknown): string | null => {
  if (typeof value !== "string" && typeof value !== "number") return null;
  const code = String(value).replace(/[^a-zA-Z0-9_.:-]/g, "").slice(0, 64);
  return code || null;
};

/** Decode all Meta statuses, preserving provider order and per-message association. */
export function detectWebhookStatusEvents(payload: any): WebhookStatusEvent[] {
  const result: WebhookStatusEvent[] = [];
  if (Array.isArray(payload?.entry)) {
    for (const rawEntry of payload.entry.slice(0, 200)) {
      const entry = asRecord(rawEntry);
      if (!Array.isArray(entry?.changes)) continue;
      for (const rawChange of entry.changes.slice(0, 200)) {
        const change = asRecord(rawChange);
        const statuses = change?.value?.statuses;
        if (!Array.isArray(statuses)) continue;
        for (const rawStatus of statuses.slice(0, 1000)) {
          const event = asRecord(rawStatus);
          if (!event || typeof event.status !== "string") continue;
          result.push({
            status: event.status,
            providerMessageId: typeof event.id === "string" ? event.id : null,
            providerErrorCode: boundedErrorCode(event.errors?.[0]?.code),
          });
        }
      }
    }
  }
  if (result.length) return result;
  // Click2API's dedicated status payload; never infer an ID from queue_id.
  const click2apiStatus = payload?.message?.message_status;
  if (typeof click2apiStatus !== "string") return result;
  const id = payload?.response?.messages?.[0]?.id;
  return [{
    status: click2apiStatus,
    providerMessageId: typeof id === "string" ? id : null,
    providerErrorCode: boundedErrorCode(payload?.message?.error_code),
  }];
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
  const statusEvents = detectWebhookStatusEvents(payload);
  return { ok: true, payload, statusEvent: statusEvents[0] ?? null, statusEvents };
}
