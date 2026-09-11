export type ApprovalApplication = {
  id: string;
  status: string | null;
  business_name: string | null;
  contact_email: string | null;
  mobile_number: string | null;
  contact_phone: string | null;
  assigned_price_tier: string | null;
};

export type ApprovalNotification = {
  subject: string;
  message: string;
  email: string | null;
  phone: string | null;
};

export type NotificationChannel = "email" | "whatsapp";

/**
 * Approval contacts follow the canonical B2B India-mobile contract used by
 * normalize_b2b_access_mobile_v2. Reject ambiguous/international values rather
 * than silently reinterpreting them as Indian recipients.
 */
export function normalizePhone(
  value: string | null | undefined,
): string | null {
  if (!value) return null;
  const digits = value.replace(/[^0-9]/g, "");
  if (/^[6-9][0-9]{9}$/.test(digits)) return `91${digits}`;
  if (/^0[6-9][0-9]{9}$/.test(digits)) return `91${digits.slice(1)}`;
  if (/^91[6-9][0-9]{9}$/.test(digits)) return digits;
  return null;
}

export function normalizeEmail(
  value: string | null | undefined,
): string | null {
  const email = value?.trim().toLowerCase() ?? "";
  if (!email || !email.includes("@") || email.length > 320) return null;
  return email;
}

export function buildApprovalNotification(
  app: ApprovalApplication,
): ApprovalNotification {
  if (app.status !== "approved") {
    throw new Error("application_not_approved");
  }

  const businessName = app.business_name?.trim() || "your business";
  const tier = app.assigned_price_tier?.trim();
  const tierLine = tier ? `\nAssigned pricing tier: ${tier}.` : "";

  return {
    subject: "Your Oasis Baklawa B2B access is approved",
    message:
      `Your B2B application for ${businessName} has been approved.${tierLine}\n\n` +
      "You can now sign in through the Oasis Baklawa Buyer login using an approved login method. " +
      "Your identity will be linked to the approved business when you complete verified sign-in.\n\n" +
      "— Team Oasis Baklawa",
    email: normalizeEmail(app.contact_email),
    phone: normalizePhone(app.mobile_number ?? app.contact_phone),
  };
}

export function approvalIdempotencyKey(
  applicationId: string,
  channel: NotificationChannel,
): string {
  return `b2b-access-approved:${applicationId}:${channel}`;
}

export function approvalChannels(
  notification: ApprovalNotification,
): NotificationChannel[] {
  const channels: NotificationChannel[] = [];
  if (notification.email) channels.push("email");
  if (notification.phone) channels.push("whatsapp");
  return channels;
}

export function isAlreadySent(status: string | null | undefined): boolean {
  return status === "sent";
}

export function safeProviderMessage(value: unknown): string {
  if (value instanceof Error) return value.message.slice(0, 500);
  if (typeof value === "string") return value.slice(0, 500);
  return "provider_send_failed";
}

export function nextApprovalAttempt(
  attemptCount: number | null | undefined,
  maxAttempts: number | null | undefined,
): { allowed: boolean; nextAttemptCount: number; maxAttempts: number } {
  const current = Number.isFinite(attemptCount) && Number(attemptCount) >= 0
    ? Number(attemptCount)
    : 0;
  const maximum = Number.isFinite(maxAttempts) && Number(maxAttempts) > 0
    ? Number(maxAttempts)
    : 5;
  return {
    allowed: current < maximum,
    nextAttemptCount: current + 1,
    maxAttempts: maximum,
  };
}
