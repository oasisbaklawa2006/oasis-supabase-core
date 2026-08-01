import { verifyChallengeToken, verifyMetaSignature } from "./whatsappWebhookSecurity.ts";

export type WebhookStatusEvent = {
  status: string;
  providerMessageId: string | null;
};

export type WebhookBoundaryResult =
  | { ok: false; status: 400 | 401 | 403 | 500; code: string }
  | { ok: true; payload: any; statusEvent: WebhookStatusEvent | null };

export function detectWebhookStatusEvent(payload: any): WebhookStatusEvent | null {
  const nestedStatus = payload?.entry?.[0]?.changes?.[0]?.value?.statuses?.[0];
  const click2apiStatus = typeof payload?.message?.message_status === "string"
    ? payload.message.message_status
    : null;

  if (!nestedStatus && !click2apiStatus) return null;

  return {
    status: nestedStatus?.status || click2apiStatus || "unknown",
    providerMessageId: nestedStatus?.id || payload?.response?.messages?.[0]?.id || null,
  };
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

  return {
    ok: true,
    payload,
    statusEvent: detectWebhookStatusEvent(payload),
  };
}
