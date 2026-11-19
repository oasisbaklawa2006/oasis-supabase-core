/**
 * WA-100: SOURCE-ONLY Meta Direct Send utility request contract.
 *
 * This module deliberately contains no HTTP transport, secrets, endpoint
 * selection, database mutations, retry, fallbacks or feature enablement.
 * The caller MUST prove transactional purpose, identity, consent, authority,
 * rate/quiet-hour eligibility and a durable idempotent claim independently.
 * Passing a purpose label to this pure builder is not proof of authorization.
 */
export const DIRECT_SEND_UTILITY_PURPOSES = [
  "ORDER_CONFIRMATION",
  "PAYMENT_RECEIPT",
  "PRODUCTION_UPDATE",
  "DISPATCH_UPDATE",
] as const;

export type DirectSendUtilityPurpose =
  (typeof DIRECT_SEND_UTILITY_PURPOSES)[number];

export type DirectSendUtilityText = {
  messaging_product: "whatsapp";
  recipient_type: "individual";
  to: string;
  type: "text";
  text: { body: string };
  category: "utility";
};

const E164 = /^\+[1-9][0-9]{7,14}$/;
const WAMID = /^wamid\.[A-Za-z0-9+/=_-]{8,}$/;

type UtilityTextInput = {
  recipientE164: string;
  body: string;
  purpose: DirectSendUtilityPurpose;
};

/**
 * Constructs a single-recipient, utility-only Meta request. An empty or
 * malformed command fails before a network client can see any payload.
 *
 * No "marketing", "authentication" or "service" category is accepted. The
 * fixed utility category is NOT a substitute for Meta category policy review.
 */
export function buildMetaDirectSendUtilityText(
  input: UtilityTextInput,
): DirectSendUtilityText {
  if (
    !input || !DIRECT_SEND_UTILITY_PURPOSES.includes(input.purpose) ||
    typeof input.recipientE164 !== "string" ||
    !E164.test(input.recipientE164)
  ) {
    throw new Error("Invalid governed utility purpose or E.164 recipient.");
  }

  if (typeof input.body !== "string" || input.body.trim().length === 0) {
    throw new Error("Utility message body must not be empty.");
  }
  // UTF-16 length is conservative for supplementary characters. Never
  // silently truncate, trim, rewrite or reclassify customer content.
  if (input.body.length > 1024) {
    throw new Error("Utility message body exceeds 1024 characters.");
  }

  return {
    messaging_product: "whatsapp",
    recipient_type: "individual",
    to: input.recipientE164.slice(1),
    type: "text",
    text: { body: input.body },
    category: "utility",
  };
}

function asRecord(input: unknown): Record<string, unknown> | null {
  return input !== null && typeof input === "object" && !Array.isArray(input)
    ? input as Record<string, unknown>
    : null;
}

export type DirectSendMetaAcceptance = {
  provider_message_id: string;
  provider_submission_status:
    | "accepted"
    | "held_for_quality_assessment"
    | "unspecified";
};

/**
 * Extracts only one genuine Meta wamid from a single-message acknowledgement.
 * Never accepts Click2API queue UUIDs, a bare HTTP 2xx, mixed/failed message
 * batches, or a fabricated SENT/DELIVERED/READ terminal status.
 *
 * A null result means acceptance has NOT been proven; the caller must use
 * its durable acceptance-unknown reconciliation policy, NEVER blind retry.
 */
export function readMetaDirectSendAcceptance(
  payload: unknown,
): DirectSendMetaAcceptance | null {
  const root = asRecord(payload);
  if (
    !root || root.messaging_product !== "whatsapp" ||
    Object.prototype.hasOwnProperty.call(root, "error") ||
    !Array.isArray(root.messages) || root.messages.length !== 1
  ) return null;

  const message = asRecord(root.messages[0]);
  if (!message || typeof message.id !== "string") return null;
  const id = message.id.trim();
  if (!WAMID.test(id)) return null;

  const status = message.message_status;
  if (
    status !== undefined && status !== "accepted" &&
    status !== "held_for_quality_assessment"
  ) return null;

  return {
    provider_message_id: id,
    provider_submission_status: status === undefined ? "unspecified" : status,
  };
}
