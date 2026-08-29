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
  completeMediaSequentially,
  formatKnowledgeSnapshotContext,
  handleAsync,
  type LoadedMessage,
  readBoundedBody,
  sanitizeInterpretation,
  trustedServiceRoleAuthorization,
  validateMime,
} from "./index.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";

// skipcq: JS-0067
function assert(
  condition: unknown,
  message = "assertion failed",
): asserts condition {
  if (!condition) throw new Error(message);
}

// skipcq: JS-0067
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

// skipcq: JS-0067
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

// skipcq: JS-0067
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

// skipcq: JS-0067
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

Deno.test("sanitizeInterpretation keeps AI advisory-only and never grants automatic authority (#CORE-C authority closure)", () => {
  const autoRaw = {
    conclusion: validConclusion({
      reply_clearance: "safe_to_send_automatically",
      human_review_required: false,
    }),
  };
  const autoResult = sanitizeInterpretation(autoRaw, messages(), []);
  const autoConclusion = autoResult.conclusion as Record<string, unknown>;
  assert(
    autoConclusion.human_review_required === true,
    "SAFE_TO_SEND_AUTOMATICALLY does not clear human_review_required",
  );
  assert(
    autoConclusion.automatic_action_authority ===
      "HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED",
    "AI reply_clearance cannot grant automatic execution authority",
  );

  const clarRaw = {
    conclusion: validConclusion({
      reply_clearance: "clarification_required",
      human_review_required: false,
    }),
  };
  const clarResult = sanitizeInterpretation(clarRaw, messages(), []);
  const clarConclusion = clarResult.conclusion as Record<string, unknown>;
  assert(
    clarConclusion.human_review_required === true,
    "CLARIFICATION_REQUIRED does not clear human_review_required",
  );
  assert(
    clarConclusion.automatic_action_authority ===
      "HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED",
    "AI cannot self-authorize clarification sends",
  );

  const sensitiveRaw = {
    conclusion: validConclusion({
      reply_clearance: "management_approval_required",
      human_review_required: false,
    }),
  };
  const sensitiveResult = sanitizeInterpretation(sensitiveRaw, messages(), []);
  const sensitiveConclusion = sensitiveResult.conclusion as Record<
    string,
    unknown
  >;
  assert(
    sensitiveConclusion.human_review_required === true,
    "sensitive clearances still require human review",
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

Deno.test("sanitizeInterpretation preserves SAFE_TO_SEND_AUTOMATICALLY without granting commercial authority", () => {
  const raw = {
    conclusion: validConclusion({
      reply_clearance: "safe_to_send_automatically",
    }),
  };
  const result = sanitizeInterpretation(raw, messages(), []);
  const conclusion = result.conclusion as Record<string, unknown>;
  assert(conclusion.reply_clearance === "SAFE_TO_SEND_AUTOMATICALLY");
  assert(
    conclusion.human_review_required === true,
    "SAFE_TO_SEND_AUTOMATICALLY is advisory only and never grants automatic authority",
  );
  assert(
    conclusion.automatic_action_authority ===
      "HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED",
    "automatic_action_authority remains fail-closed",
  );
});

Deno.test("completeMediaSequentially ignores cached warnings and completes only explicit ids (#84)", async () => {
  const completed: string[] = [];
  const mockAdmin = {
    rpc: (_name: string, args: Record<string, unknown>) => {
      completed.push(String(args.p_provider_message_id));
      return Promise.resolve({ error: null });
    },
  } as unknown as SupabaseClient;

  const cachedWarnings = ["wa-img-1: MEDIA_TOO_LARGE"];
  assert(
    cachedWarnings.some((warning) => warning.includes("wa-img-1")),
    "cached interpretation warnings may reference media ids without proving processing",
  );

  await completeMediaSequentially(mockAdmin, [], "fingerprint");
  assert(
    completed.length === 0,
    "unprocessed media must not be marked complete when processedMediaIds is empty",
  );

  await completeMediaSequentially(mockAdmin, ["wa-img-1"], "fingerprint");
  assert(
    JSON.stringify(completed) === JSON.stringify(["wa-img-1"]),
    "only ids from the current invocation processedMediaIds may be completed",
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

Deno.test("handleAsync resolves Supabase-shaped thenables via Promise.resolve", async () => {
  const thenable: PromiseLike<string> = Promise.resolve("thenable-ok");
  const [value, error] = await handleAsync(thenable);
  assert(value === "thenable-ok", "thenable value should resolve");
  assert(error === undefined, "thenable transport should not error");
});

Deno.test("formatKnowledgeSnapshotContext rejects oversized knowledge payloads", () => {
  const huge = "x".repeat(13000);
  try {
    formatKnowledgeSnapshotContext({
      id: "86300000-0000-0000-0000-000000000011",
      schema_version: "wa-knowledge/v2",
      content_checksum:
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd",
      knowledge: { blob: huge },
    });
    throw new Error("oversized knowledge must fail closed");
  } catch (error) {
    assert(
      error instanceof Error &&
        error.message === "KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE",
      "oversized knowledge must use explicit failure code",
    );
  }
});

const jwtForWorkerRole = (role: string): string => {
  const encode = (value: Record<string, unknown>) =>
    btoa(JSON.stringify(value))
      .replace(/\+/g, "-")
      .replace(/\//g, "_")
      .replace(/=+$/g, "");

  return `${encode({ alg: "HS256", typ: "JWT" })}.${
    encode({
      role,
      ref: "cert-preview",
    })
  }.gateway-validated-signature`;
};

Deno.test("worker accepts gateway-validated service_role JWT", () => {
  assert(
    trustedServiceRoleAuthorization(
      `Bearer ${jwtForWorkerRole("service_role")}`,
    ),
    "service_role JWT must pass the worker's secondary authorization gate",
  );
});

Deno.test("worker rejects authenticated and anon JWT roles", () => {
  assert(
    !trustedServiceRoleAuthorization(
      `Bearer ${jwtForWorkerRole("authenticated")}`,
    ),
    "authenticated user JWT must not invoke the trusted worker",
  );
  assert(
    !trustedServiceRoleAuthorization(
      `Bearer ${jwtForWorkerRole("anon")}`,
    ),
    "anon JWT must not invoke the trusted worker",
  );
});

Deno.test("worker rejects missing malformed and non-JWT bearer credentials", () => {
  assert(!trustedServiceRoleAuthorization(""));
  assert(!trustedServiceRoleAuthorization("Bearer"));
  assert(!trustedServiceRoleAuthorization("Bearer not-a-jwt"));
  assert(!trustedServiceRoleAuthorization("Bearer sb_secret_example"));
  assert(!trustedServiceRoleAuthorization("Basic abc"));
});
