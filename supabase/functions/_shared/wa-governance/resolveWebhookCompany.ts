import type { SupabaseClient } from "https://esm.sh/@supabase/supabase-js@2.45.0";

/** Governed company resolution outcome for whatsapp-webhook intake. */
export type WebhookCompanyResolution = {
  companyId: string | null;
  companyName: string;
  accountManagerId: string | null;
  resolutionStatus: "RESOLVED" | "AMBIGUOUS" | "UNRESOLVED";
  matchMethod: string | null;
  details: Record<string, unknown>;
};

export type GovernedCustomerRow = {
  company_id: string | null;
  business_name: string | null;
  gst_number: string | null;
  payment_terms: string | null;
  is_frozen: boolean | null;
  resolution_status: string | null;
  match_method: string | null;
  confidence: number | null;
  details: Record<string, unknown> | null;
};

export type WebhookIdentityContext = {
  contactId: string;
  profileName?: string | null;
  messageBody?: string | null;
  senderIsStaffProxy: boolean;
  explicitCompanyId?: string | null;
  isForwarded?: boolean;
  forwardedFromPhone?: string | null;
  originalCommunicatorPhone?: string | null;
};

const GST_PATTERN = /\b([0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z])\b/i;

/** Lightweight company-name extraction for governed exact-name candidate only. */
export function extractCompanyNameFromText(text: string): string | null {
  if (!text) return null;
  const patterns = [
    /(?:from|for|m\/s\.?|client|company)\s*[:\-]?\s*([A-Z][A-Za-z0-9 &.\-]{2,40})/i,
    /([A-Z][A-Za-z]+(?:\s+[A-Z][A-Za-z]+){0,3})\s+(?:traders|enterprises|sweets|foods|catering|hotel|restaurant|stores|paharganj|bakery)/i,
  ];
  for (const re of patterns) {
    const m = text.match(re);
    if (m?.[1]) return m[1].trim();
  }
  return null;
}

/** Staff relay messages may name a client explicitly; pass exact candidate to Core RPC. */
export function extractStaffMentionedClient(messageBody: string): string | null {
  if (!messageBody) return null;
  const clientPatterns = [
    /(?:order\s+for|client|customer|party|for\s+M\/s\.?|for)\s+[:\-]?\s*([A-Z0-9][A-Za-z0-9\s&'.]+)/i,
    /([A-Z0-9][A-Za-z0-9\s&'.]{3,})\s+(?:ka|ke|ki|order|wants?|need)/i,
  ];
  for (const pat of clientPatterns) {
    const m = messageBody.match(pat);
    if (m?.[1]) return m[1].trim();
  }
  return null;
}

export function extractGstFromText(text: string): string | null {
  if (!text) return null;
  const m = text.match(GST_PATTERN);
  return m?.[1] ? m[1].toUpperCase() : null;
}

export type PayloadIdentityFields = {
  isForwarded: boolean;
  forwardedFromPhone: string | null;
  originalCommunicatorPhone: string | null;
  explicitCompanyId: string | null;
};

/** Extract forwarded/original-customer provenance without inferring commercial customer. */
export function extractPayloadIdentityFields(payload: Record<string, unknown>): PayloadIdentityFields {
  const entry = (payload?.entry as unknown[] | undefined)?.[0] as Record<string, unknown> | undefined;
  const changes = (entry?.changes as unknown[] | undefined)?.[0] as Record<string, unknown> | undefined;
  const value = changes?.value as Record<string, unknown> | undefined;
  const msg = (value?.messages as unknown[] | undefined)?.[0] as Record<string, unknown> | undefined;
  const context = msg?.context as Record<string, unknown> | undefined;

  const m91 =
    (payload?.payload as Record<string, unknown> | undefined)?.message
      ? (payload.payload as Record<string, unknown>)
      : (payload?.data as Record<string, unknown> | undefined)?.payload
        ? ((payload.data as Record<string, unknown>).payload as Record<string, unknown>)
        : (payload?.payload as Record<string, unknown> | undefined)?.mobile ||
            (payload?.payload as Record<string, unknown> | undefined)?.from ||
            (payload?.payload as Record<string, unknown> | undefined)?.sender
          ? (payload.payload as Record<string, unknown>)
          : null;

  const message = (m91?.message as Record<string, unknown> | undefined) ?? {};
  const m91Context = (message?.context as Record<string, unknown> | undefined) ??
    (m91?.context as Record<string, unknown> | undefined);

  const forwardedFlag =
    context?.forwarded === true ||
    context?.frequently_forwarded === true ||
    m91Context?.forwarded === true ||
    m91Context?.frequently_forwarded === true ||
    payload?.forwarded === true ||
    (payload?.data as Record<string, unknown> | undefined)?.forwarded === true;

  const bodyText = typeof msg?.text === "object"
    ? String((msg.text as Record<string, unknown>)?.body ?? "")
    : typeof message?.text === "string"
      ? message.text
      : typeof (message?.text as Record<string, unknown> | undefined)?.body === "string"
        ? String((message.text as Record<string, unknown>).body)
        : "";

  const forwardedBodyHint = /^forwarded message/i.test(bodyText.trim());

  const forwardedFrom =
    stringOrNull(context?.forwarded_from) ??
    stringOrNull(m91Context?.forwarded_from) ??
    stringOrNull(payload?.forwarded_from) ??
    stringOrNull((payload?.data as Record<string, unknown> | undefined)?.forwarded_from) ??
    stringOrNull((payload?.metadata as Record<string, unknown> | undefined)?.forwarded_from);

  const originalCommunicator =
    stringOrNull(context?.original_sender) ??
    stringOrNull(m91Context?.original_sender) ??
    stringOrNull(payload?.original_sender) ??
    stringOrNull((payload?.metadata as Record<string, unknown> | undefined)?.original_sender) ??
    forwardedFrom;

  const explicitCompanyId =
    stringOrNull(payload?.company_id) ??
    stringOrNull((payload?.data as Record<string, unknown> | undefined)?.company_id) ??
    stringOrNull((payload?.metadata as Record<string, unknown> | undefined)?.company_id);

  return {
    isForwarded: forwardedFlag || forwardedBodyHint,
    forwardedFromPhone: forwardedFrom,
    originalCommunicatorPhone: originalCommunicator,
    explicitCompanyId,
  };
}

function stringOrNull(value: unknown): string | null {
  if (typeof value !== "string") return null;
  const trimmed = value.trim();
  return trimmed.length > 0 ? trimmed : null;
}

/** Build governed candidate JSON for whatsapp_resolve_governed_customer. */
export function buildGovernedCandidate(input: WebhookIdentityContext): Record<string, string> {
  const candidate: Record<string, string> = {};

  if (input.explicitCompanyId) {
    candidate.company_id = input.explicitCompanyId;
  }

  const mentionedClient = input.senderIsStaffProxy
    ? extractStaffMentionedClient(input.messageBody ?? "")
    : null;
  const extractedName = extractCompanyNameFromText(input.messageBody ?? "");
  const candidateName = mentionedClient ?? extractedName;
  if (candidateName) {
    candidate.company_name = candidateName;
    candidate.business_name = candidateName;
  }

  const gst = extractGstFromText(input.messageBody ?? "");
  if (gst) {
    candidate.gst_number = gst;
  }

  if (input.isForwarded && input.originalCommunicatorPhone) {
    candidate.original_communicator_phone = input.originalCommunicatorPhone;
  }

  return candidate;
}

export function mapGovernedCustomerRow(row: GovernedCustomerRow | null | undefined): WebhookCompanyResolution {
  const status = normalizeResolutionStatus(row?.resolution_status);
  const companyId = row?.company_id ?? null;
  const companyName = row?.business_name ?? "Unknown";
  const accountManagerId =
    typeof row?.details?.account_manager_id === "string"
      ? row.details.account_manager_id
      : null;

  return {
    companyId: status === "RESOLVED" ? companyId : null,
    companyName,
    accountManagerId,
    resolutionStatus: status,
    matchMethod: row?.match_method ?? null,
    details: {
      ...(row?.details ?? {}),
      confidence: row?.confidence ?? null,
      gst_number: row?.gst_number ?? null,
      is_frozen: row?.is_frozen ?? null,
    },
  };
}

function normalizeResolutionStatus(value: string | null | undefined): "RESOLVED" | "AMBIGUOUS" | "UNRESOLVED" {
  if (value === "RESOLVED") return "RESOLVED";
  if (value === "AMBIGUOUS") return "AMBIGUOUS";
  return "UNRESOLVED";
}

/**
 * Resolve commercial customer via Core governed RPC only.
 * Never fuzzy-links, never creates shadow companies, never retargets orders.
 */
export async function resolveWebhookCompany(
  supabaseAdmin: SupabaseClient,
  input: WebhookIdentityContext,
): Promise<WebhookCompanyResolution> {
  const candidate = buildGovernedCandidate(input);

  const { data, error } = await supabaseAdmin.rpc(
    "whatsapp_resolve_governed_customer",
    {
      p_contact_id: input.contactId,
      p_candidate: candidate,
    },
  );

  if (error) {
    return {
      companyId: null,
      companyName: input.profileName ?? "Unknown",
      accountManagerId: null,
      resolutionStatus: "UNRESOLVED",
      matchMethod: "RPC_ERROR",
      details: { error: error.message, candidate },
    };
  }

  const row = Array.isArray(data) ? (data[0] as GovernedCustomerRow | undefined) : (data as GovernedCustomerRow | undefined);
  const mapped = mapGovernedCustomerRow(row);

  if (mapped.resolutionStatus !== "RESOLVED") {
    return {
      ...mapped,
      companyName: input.profileName ?? mapped.companyName ?? "Unknown",
      companyId: null,
    };
  }

  if (mapped.companyId) {
    const { data: companyRow } = await supabaseAdmin
      .from("companies")
      .select("account_manager_id")
      .eq("id", mapped.companyId)
      .maybeSingle();
    if (companyRow?.account_manager_id) {
      mapped.accountManagerId = companyRow.account_manager_id;
    }
  }

  return mapped;
}

/** Relay/forwarded senders must not become commercial customer from sender phone alone. */
export function shouldBlockSenderPhoneInference(input: WebhookIdentityContext): boolean {
  return input.senderIsStaffProxy || input.isForwarded === true;
}
