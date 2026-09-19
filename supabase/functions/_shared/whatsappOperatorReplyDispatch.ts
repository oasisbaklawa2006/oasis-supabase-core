import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { selectClick2ApiProviderMessageId } from "./whatsappProviderAcceptance.ts";

const CLICK2API_ENDPOINT = "https://crm.click2api.in/api/v1/messages";

export function providerCredentialsConfigured(): boolean {
  return Boolean(Deno.env.get("CLICK2API_API_KEY")?.trim());
}

export type OperatorReplyRow = {
  id: string;
  lease_token: string;
  message_type: string;
  recipient_phone_e164: string;
  message_body: string;
  template_name: string | null;
  template_language: string | null;
  message_origin: string;
  status: string;
};

export class OperatorReplyDispatchError extends Error {
  constructor(
    readonly code: string,
    message?: string,
  ) {
    super(message ?? code);
    this.name = "OperatorReplyDispatchError";
  }
}

function parseClaimRow(data: unknown): OperatorReplyRow | null {
  if (!data) return null;
  const row = data as Record<string, unknown>;
  const id = typeof row.id === "string" ? row.id : "";
  const leaseToken = typeof row.lease_token === "string" ? row.lease_token : "";
  if (!id || !leaseToken) return null;
  return {
    id,
    lease_token: leaseToken,
    message_type: String(row.message_type ?? "TEXT"),
    recipient_phone_e164: String(row.recipient_phone_e164 ?? ""),
    message_body: String(row.message_body ?? ""),
    template_name: typeof row.template_name === "string"
      ? row.template_name
      : null,
    template_language: typeof row.template_language === "string"
      ? row.template_language
      : null,
    message_origin: String(row.message_origin ?? "STAFF"),
    status: String(row.status ?? ""),
  };
}

function buildProviderPayload(row: OperatorReplyRow): Record<string, unknown> {
  const to = row.recipient_phone_e164.replace(/^\+/, "");
  if (row.message_type === "TEMPLATE") {
    return {
      messaging_product: "whatsapp",
      to,
      type: "template",
      template: {
        name: row.template_name,
        language: { code: row.template_language },
      },
    };
  }
  return {
    messaging_product: "whatsapp",
    to,
    type: "text",
    text: { body: row.message_body },
  };
}

async function rpcOrThrow<T>(
  label: string,
  promise: PromiseLike<{ data: T; error: { message: string } | null }>,
): Promise<T> {
  const { data, error } = await promise;
  if (error) {
    throw new OperatorReplyDispatchError(label, error.message.slice(0, 240));
  }
  return data;
}

export async function claimNextOperatorReply(
  admin: SupabaseClient,
  workerId: string,
  replyId?: string | null,
): Promise<OperatorReplyRow | null> {
  const data = await rpcOrThrow(
    "CLAIM_FAILED",
    admin.rpc("claim_whatsapp_operator_reply", {
      p_worker_id: workerId,
      p_reply_id: replyId ?? null,
      p_lease_seconds: 60,
    }),
  );
  return parseClaimRow(data);
}

export async function dispatchClaimedOperatorReply(
  admin: SupabaseClient,
  row: OperatorReplyRow,
): Promise<{ provider_message_id: string; status: string }> {
  const apiKey = Deno.env.get("CLICK2API_API_KEY");
  const token = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  if (!apiKey) {
    await rpcOrThrow(
      "FAIL_NOT_CONFIGURED",
      admin.rpc("fail_whatsapp_operator_reply", {
        p_reply_id: row.id,
        p_lease_token: row.lease_token,
        p_error_code: "PROVIDER_NOT_CONFIGURED",
        p_error_detail: "CLICK2API_API_KEY absent",
        p_acceptance_unknown: false,
      }),
    );
    throw new OperatorReplyDispatchError("PROVIDER_NOT_CONFIGURED");
  }

  let providerResponse: Response;
  try {
    providerResponse = await fetch(CLICK2API_ENDPOINT, {
      method: "POST",
      signal: AbortSignal.timeout(20_000),
      headers: {
        "Content-Type": "application/json",
        apikey: apiKey,
        ...(token ? { Authorization: `Bearer ${token}` } : {}),
      },
      body: JSON.stringify(buildProviderPayload(row)),
    });
  } catch (error) {
    await rpcOrThrow(
      "FAIL_NETWORK",
      admin.rpc("fail_whatsapp_operator_reply", {
        p_reply_id: row.id,
        p_lease_token: row.lease_token,
        p_error_code: "NETWORK_TIMEOUT",
        p_error_detail: error instanceof Error ? error.message : String(error),
        p_acceptance_unknown: true,
      }),
    );
    return { provider_message_id: "", status: "ACCEPTANCE_UNKNOWN" };
  }

  const providerBody = await providerResponse.json().catch(() => ({}));
  const providerId = selectClick2ApiProviderMessageId(providerBody);
  if (providerResponse.ok && providerId != null) {
    const completed = await rpcOrThrow(
      "COMPLETE_FAILED",
      admin.rpc("complete_whatsapp_operator_reply", {
        p_reply_id: row.id,
        p_lease_token: row.lease_token,
        p_provider: "click2api",
        p_provider_message_id: String(providerId),
      }),
    );
    return {
      provider_message_id: String(providerId),
      status: String(
        (completed as Record<string, unknown>).status ?? "ACCEPTED",
      ),
    };
  }

  const acceptanceUnknown = providerResponse.ok;
  await rpcOrThrow(
    "FAIL_PROVIDER",
    admin.rpc("fail_whatsapp_operator_reply", {
      p_reply_id: row.id,
      p_lease_token: row.lease_token,
      p_error_code: acceptanceUnknown
        ? `HTTP_${providerResponse.status}_NO_PROVIDER_ID`
        : `HTTP_${providerResponse.status}`,
      p_error_detail: JSON.stringify(providerBody).slice(0, 2000) ||
        "Provider rejected request",
      p_acceptance_unknown: acceptanceUnknown,
    }),
  );
  return {
    provider_message_id: "",
    status: acceptanceUnknown ? "ACCEPTANCE_UNKNOWN" : "FAILED_RETRYABLE",
  };
}

export async function consumeAvailableReplies(
  admin: SupabaseClient,
  workerId: string,
  maxReplies: number,
): Promise<Record<string, unknown>> {
  if (!providerCredentialsConfigured()) {
    return {
      success: false,
      idle: true,
      processed: 0,
      failed: 1,
      errors: ["PROVIDER_NOT_CONFIGURED"],
    };
  }

  let processed = 0;
  let failed = 0;
  const errors: string[] = [];

  for (let index = 0; index < maxReplies; index += 1) {
    let claimed: OperatorReplyRow | null;
    try {
      claimed = await claimNextOperatorReply(admin, workerId);
    } catch (error) {
      const code = error instanceof OperatorReplyDispatchError
        ? error.code
        : "CLAIM_FAILED";
      failed += 1;
      errors.push(code);
      break;
    }

    if (!claimed) {
      return {
        success: failed === 0,
        idle: processed === 0 && failed === 0,
        processed,
        failed,
        errors,
      };
    }

    try {
      const outcome = await dispatchClaimedOperatorReply(admin, claimed);
      if (outcome.status === "ACCEPTANCE_UNKNOWN") {
        failed += 1;
        errors.push("ACCEPTANCE_UNKNOWN");
      } else if (
        outcome.status.startsWith("FAILED") ||
        outcome.status === "FAILED_FINAL"
      ) {
        failed += 1;
        errors.push(outcome.status);
      } else {
        processed += 1;
      }
    } catch (error) {
      const code = error instanceof OperatorReplyDispatchError
        ? error.code
        : "DISPATCH_FAILED";
      failed += 1;
      errors.push(code);
      if (code === "PROVIDER_NOT_CONFIGURED") break;
    }
  }

  return {
    success: failed === 0,
    idle: false,
    processed,
    failed,
    errors,
  };
}
