import { verifyChallengeToken, verifyMetaSignature } from "./whatsappWebhookSecurity.ts";

export type WebhookStatusEvent = {
  status: string;
  providerMessageId: string | null;
};

export type WebhookBoundaryResult =
  | { ok: false; status: 400 | 401 | 403 | 500; code: string }
  | {
      ok: true;
      payload: any;
      statusEvent: WebhookStatusEvent | null;
      statusEvents: WebhookStatusEvent[];
    };

export function detectWebhookStatusEvents(payload: any): WebhookStatusEvent[] {
  const events: WebhookStatusEvent[] = [];
  const entries = Array.isArray(payload?.entry) ? payload.entry : [];

  for (const entry of entries) {
    const changes = Array.isArray(entry?.changes) ? entry.changes : [];
    for (const change of changes) {
      const statuses = Array.isArray(change?.value?.statuses)
        ? change.value.statuses
        : [];
      for (const status of statuses) {
        if (typeof status?.status !== "string") continue;
        events.push({
          status: status.status,
          providerMessageId: typeof status?.id === "string" ? status.id : null,
        });
      }
    }
  }

  if (events.length > 0) return events;

  const click2apiStatus = typeof payload?.message?.message_status === "string"
    ? payload.message.message_status
    : null;
  if (!click2apiStatus) return [];

  return [{
    status: click2apiStatus,
    providerMessageId: typeof payload?.response?.messages?.[0]?.id === "string"
      ? payload.response.messages[0].id
      : null,
  }];
}

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
  return {
    ok: true,
    payload,
    statusEvent: statusEvents[0] ?? null,
    statusEvents,
  };
}
