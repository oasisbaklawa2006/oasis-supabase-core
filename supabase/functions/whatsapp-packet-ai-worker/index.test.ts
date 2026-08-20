// Unit coverage for the whatsapp-packet-ai-worker synthesis (Central issue
// #368 migration-train normalization, PROCEED phase 2A sections C-G): PR
// #82's security/runtime hardening merged with PR #84's B2B case-routing
// fields, layered onto #82's strict sanitizeInterpretation() rather than
// #84's raw-JSON acceptance. This covers the pure, DB/network-free surface
// only -- the full request handler requires a live Supabase project and
// Lovable AI Gateway credentials, so end-to-end request/response behavior
// is exercised by pgTAP contracts and physical certification, not here.
import {
  allowedMediaUrl,
  type LoadedMessage,
  readBoundedBody,
  sanitizeInterpretation,
  validateMime,
} from "./index.ts";

function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

function assertThrows(fn: () => unknown, pattern: RegExp) {
  try {
    fn();
  } catch (error) {
    assert(
      error instanceof Error && pattern.test(error.message),
      `unexpected error: ${String(error)}`,
    );
    return;
  }
  throw new Error("expected function to throw");
}

function messages(overrides: Partial<LoadedMessage>[] = []): LoadedMessage[] {
  const base: LoadedMessage = {
    providerMessageId: "wa-msg-1",
    content: "hello",
    messageType: "text",
    mediaUrl: "",
    timestamp: "2026-08-19T00:00:00Z",
  };
  if (overrides.length === 0) return [base];
  return overrides.map((partial, index) => ({
    ...base,
    providerMessageId: `wa-msg-${index + 1}`,
    ...partial,
  }));
}

function validConclusion(overrides: Record<string, unknown> = {}) {
  return {
    intent: "NEW_ORDER",
    summary: "Customer wants 50 boxes of baklawa.",
    recommended_action: "Confirm stock and price with sales.",
    explicit_facts: [],
    order_lines: [],
    corrections: [],
    ambiguities: [],
    ...overrides,
  };
}

// --- #82 security/runtime hardening survives ------------------------------

Deno.test("allowedMediaUrl rejects non-https and credentialed URLs (#82 hardening)", () => {
  assertThrows(
    () => allowedMediaUrl("http://click2api.in/media/1"),
    /MEDIA_URL_PROTOCOL_NOT_ALLOWED/,
  );
  assertThrows(
    () => allowedMediaUrl("https://user:pass@click2api.in/media/1"),
    /MEDIA_URL_CREDENTIALS_NOT_ALLOWED/,
  );
  assertThrows(
    () => allowedMediaUrl("https://evil.example.com/media/1"),
    /MEDIA_HOST_NOT_ALLOWED/,
  );
  const url = allowedMediaUrl("https://click2api.in/media/1");
  assert(url.hostname === "click2api.in");
});

Deno.test("readBoundedBody enforces the byte ceiling (#82 hardening)", async () => {
  const bigChunk = new Uint8Array(10);
  const stream = new ReadableStream<Uint8Array>({
    start(controller) {
      controller.enqueue(bigChunk);
      controller.enqueue(bigChunk);
      controller.close();
    },
  });
  const response = new Response(stream);
  await assertRejects(() => readBoundedBody(response, 15), /MEDIA_TOO_LARGE/);
});

async function assertRejects(fn: () => Promise<unknown>, pattern: RegExp) {
  try {
    await fn();
  } catch (error) {
    assert(
      error instanceof Error && pattern.test(error.message),
      `unexpected error: ${String(error)}`,
    );
    return;
  }
  throw new Error("expected promise to reject");
}

Deno.test("validateMime rejects a mismatched declared type (#82 hardening)", () => {
  assertThrows(
    () => validateMime("image", "application/pdf"),
    /UNSUPPORTED_IMAGE_TYPE/,
  );
  validateMime("document", "application/pdf");
});

Deno.test("sanitizeInterpretation rejects a non-schema payload (#82 hardening)", () => {
  assertThrows(
    () => sanitizeInterpretation(null, messages(), []),
    /INTERPRETER_INVALID_SCHEMA/,
  );
  assertThrows(
    () => sanitizeInterpretation({}, messages(), []),
    /INTERPRETER_INVALID_SCHEMA/,
  );
  assertThrows(
    () =>
      sanitizeInterpretation(
        {
          conclusion: {
            intent: "NOT_A_REAL_INTENT",
            summary: "x",
            recommended_action: "x",
          },
        },
        messages(),
        [],
      ),
    /INTERPRETER_INVALID_SCHEMA/,
  );
});

Deno.test("sanitizeInterpretation rejects provenance outside the packet (#82 hardening)", () => {
  const raw = {
    conclusion: validConclusion({
      explicit_facts: [{
        provider_message_id: "not-in-packet",
        kind: "quantity",
        value: "50",
      }],
    }),
  };
  assertThrows(
    () => sanitizeInterpretation(raw, messages(), []),
    /INTERPRETER_INVALID_PROVENANCE/,
  );
});

Deno.test("sanitizeInterpretation always forces human_review_required=true (#82 + #84)", () => {
  const raw = { conclusion: validConclusion({ human_review_required: false }) };
  const result = sanitizeInterpretation(raw, messages(), []);
  const conclusion = result.conclusion as Record<string, unknown>;
  assert(
    conclusion.human_review_required === true,
    "human_review_required must always be true",
  );
});

// --- #84 routing fields (section D allowlists) -----------------------------

Deno.test("sanitizeInterpretation preserves valid routing fields (#84 capability)", () => {
  const raw = {
    conclusion: validConclusion({
      primary_department: "sales",
      contributor_departments: ["finance", "dispatch"],
      reply_clearance: "clarification_required",
      draft_reply: "Thanks, we will confirm stock shortly.",
    }),
  };
  const result = sanitizeInterpretation(raw, messages(), []);
  const conclusion = result.conclusion as Record<string, unknown>;
  assert(
    conclusion.primary_department === "SALES",
    "primary_department should survive sanitization uppercased",
  );
  assert(
    JSON.stringify(conclusion.contributor_departments) ===
      JSON.stringify(["FINANCE", "DISPATCH"]),
    "contributor_departments should survive sanitization",
  );
  assert(
    conclusion.reply_clearance === "CLARIFICATION_REQUIRED",
    "reply_clearance should survive sanitization",
  );
  assert(
    conclusion.draft_reply === "Thanks, we will confirm stock shortly.",
    "draft_reply should survive sanitization",
  );
});

Deno.test("sanitizeInterpretation rejects/normalizes unsupported department and clearance fail-closed", () => {
  const raw = {
    conclusion: validConclusion({
      primary_department: "NOT_A_REAL_DEPARTMENT",
      contributor_departments: ["NOT_A_REAL_DEPARTMENT", "FINANCE"],
      reply_clearance: "NOT_A_REAL_CLEARANCE",
    }),
  };
  const result = sanitizeInterpretation(raw, messages(), []);
  const conclusion = result.conclusion as Record<string, unknown>;
  assert(
    conclusion.primary_department === "",
    "unsupported primary_department must not pass through",
  );
  assert(
    JSON.stringify(conclusion.contributor_departments) ===
      JSON.stringify(["FINANCE"]),
    "unsupported contributor_departments entries must be dropped, valid ones kept",
  );
  assert(
    conclusion.reply_clearance === "EMPLOYEE_REVIEW_REQUIRED",
    "unsupported reply_clearance must fail closed to the conservative default, never SAFE_TO_SEND_AUTOMATICALLY",
  );
});

Deno.test("sanitizeInterpretation never accepts SAFE_TO_SEND_AUTOMATICALLY as authorization to send", () => {
  const raw = {
    conclusion: validConclusion({
      reply_clearance: "safe_to_send_automatically",
    }),
  };
  const result = sanitizeInterpretation(raw, messages(), []);
  const conclusion = result.conclusion as Record<string, unknown>;
  // The value itself is legitimate advisory data and is preserved verbatim...
  assert(conclusion.reply_clearance === "SAFE_TO_SEND_AUTOMATICALLY");
  // ...but it must never suppress the permanent human-review boundary.
  assert(
    conclusion.human_review_required === true,
    "SAFE_TO_SEND_AUTOMATICALLY must not bypass human_review_required",
  );
});

Deno.test("sanitizeInterpretation accepts the full #84 intent taxonomy", () => {
  for (
    const intent of [
      "NEW_ORDER",
      "AMENDMENT",
      "CANCELLATION",
      "ENQUIRY",
      "COMPLAINT",
      "PAYMENT_ADVICE",
      "ACCOUNT_QUERY",
      "DELIVERY_QUERY",
      "SPECIFICATION_QUERY",
      "OTHER",
      "UNCLEAR",
    ]
  ) {
    const raw = { conclusion: validConclusion({ intent }) };
    const result = sanitizeInterpretation(raw, messages(), []);
    assert(
      (result.conclusion as Record<string, unknown>).intent === intent,
      `intent ${intent} should be accepted`,
    );
  }
});
