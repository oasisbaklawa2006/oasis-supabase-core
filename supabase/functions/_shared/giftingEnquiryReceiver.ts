// HTTP boundary for the Gifting website enquiry receiver (Central #677, Gifting PR #37).
//
// Pure request handling so it can be tested without Supabase or the network. The caller
// supplies `receive`, which wraps public.gifting_enquiry_receive_v1 (service_role only).
// Authentication is the Connect bearer token itself, verified inside that RPC.

export const MAX_BODY_BYTES = 16 * 1024;

const UUID_RE =
  /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

export type ReceiveResult = {
  data: unknown;
  error: { message?: string; code?: string } | null;
};

export type ReceiveFn = (
  token: string,
  sourceLeadId: string,
  payload: Record<string, unknown>,
) => Promise<ReceiveResult>;

function json(
  status: number,
  body: unknown,
  extra: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      "content-type": "application/json",
      "cache-control": "no-store",
      ...extra,
    },
  });
}

function unauthorized(): Response {
  return json(401, { error: "unauthorized" }, {
    "www-authenticate": 'Bearer realm="gifting-enquiries"',
  });
}

/** Map a database exception to a stable HTTP result without echoing internal detail. */
export function mapReceiveError(
  error: { message?: string; code?: string },
): Response {
  const message = error.message ?? "";
  if (
    message.startsWith("CONNECT_TOKEN_INVALID") ||
    message.startsWith("CONNECT_AUTHORIZATION_DENIED")
  ) {
    return unauthorized();
  }
  if (message.startsWith("CONNECT_SCOPE_DENIED")) {
    return json(403, { error: "forbidden" });
  }
  if (message.startsWith("GIFTING_ENQUIRY_PAYLOAD_CONFLICT")) {
    return json(409, { error: "payload_conflict" });
  }
  if (message.startsWith("GIFTING_ENQUIRY_INVALID")) {
    return json(422, { error: "invalid_payload" });
  }
  // Anything else is an infrastructure fault: the sender must retry with the same key.
  return json(503, { error: "unavailable" }, { "retry-after": "30" });
}

export async function handleGiftingEnquiryRequest(
  req: Request,
  receive: ReceiveFn,
): Promise<Response> {
  if (req.method !== "POST") {
    return json(405, { error: "method_not_allowed" }, { allow: "POST" });
  }

  const authorization = req.headers.get("authorization") ?? "";
  const match = /^Bearer\s+(\S+)$/i.exec(authorization);
  if (!match) return unauthorized();
  const token = match[1]!;

  const idempotencyKey = (req.headers.get("idempotency-key") ?? "").trim();
  if (!UUID_RE.test(idempotencyKey)) {
    return json(400, { error: "idempotency_key_required" });
  }

  const contentType = req.headers.get("content-type")?.split(";")[0]?.trim()
    .toLowerCase();
  if (contentType !== "application/json") {
    return json(415, { error: "unsupported_media_type" });
  }

  const declared = Number(req.headers.get("content-length") ?? "0");
  if (Number.isFinite(declared) && declared > MAX_BODY_BYTES) {
    return json(413, { error: "payload_too_large" });
  }

  let raw: string;
  try {
    const reader = req.body?.getReader();
    const chunks: Uint8Array[] = [];
    let size = 0;
    if (reader) {
      try {
        while (true) {
          const { value, done } = await reader.read();
          if (done) break;
          size += value.byteLength;
          if (size > MAX_BODY_BYTES) {
            // Do not wait for an untrusted source to finish cancelling.
            void reader.cancel().catch(() => {});
            return json(413, { error: "payload_too_large" });
          }
          chunks.push(value);
        }
      } finally {
        reader.releaseLock();
      }
    }
    const bytes = new Uint8Array(size);
    let offset = 0;
    for (const chunk of chunks) {
      bytes.set(chunk, offset);
      offset += chunk.byteLength;
    }
    raw = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
  } catch {
    return json(400, { error: "invalid_json" });
  }

  let payload: unknown;
  try {
    payload = JSON.parse(raw);
  } catch {
    return json(400, { error: "invalid_json" });
  }
  if (
    payload === null || typeof payload !== "object" || Array.isArray(payload)
  ) {
    return json(422, { error: "invalid_payload" });
  }

  // PostgreSQL jsonb cannot represent NUL or unpaired UTF-16 surrogates.
  // Walk iteratively so deeply nested, bounded JSON cannot overflow the call stack.
  const pending: unknown[] = [payload];
  while (pending.length) {
    const value = pending.pop();
    if (typeof value === "string") {
      for (const character of value) {
        const codePoint = character.codePointAt(0)!;
        if (codePoint === 0 || (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
          return json(422, { error: "invalid_payload" });
        }
      }
    } else if (value !== null && typeof value === "object") {
      for (const [key, child] of Object.entries(value)) {
        pending.push(key, child);
      }
    }
  }

  let result: ReceiveResult;
  try {
    result = await receive(
      token,
      idempotencyKey.toLowerCase(),
      payload as Record<string, unknown>,
    );
  } catch {
    return json(503, { error: "unavailable" }, { "retry-after": "30" });
  }
  if (result.error) return mapReceiveError(result.error);

  const receipt = result.data as Record<string, unknown> | null;
  if (
    !receipt ||
    receipt.status !== "accepted" ||
    receipt.queue !== "gifting_enquiries" ||
    typeof receipt.sourceLeadId !== "string" ||
    typeof receipt.enquiryId !== "string"
  ) {
    return json(503, { error: "unavailable" }, { "retry-after": "30" });
  }

  return json(receipt.replayed === true ? 200 : 201, {
    status: "accepted",
    queue: "gifting_enquiries",
    sourceLeadId: receipt.sourceLeadId,
    enquiryId: receipt.enquiryId,
    replayed: receipt.replayed === true,
  });
}
