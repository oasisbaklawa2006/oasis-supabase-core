import {
  durablePersistenceFailed,
  evaluateWhatsappMessagesPersistence,
} from "./whatsappWebhookDurablePersistence.ts";

Deno.test("successful durable insert permits provider acknowledgement", () => {
  const decision = evaluateWhatsappMessagesPersistence(
    true,
    "contact-uuid",
    null,
  );
  if (!decision.ok || decision.duplicate) {
    throw new Error("expected persisted non-duplicate outcome");
  }
  if (durablePersistenceFailed(true, "contact-uuid", null, false)) {
    throw new Error("expected persistence success");
  }
});

Deno.test("duplicate provider_message_id (23505) permits provider acknowledgement", () => {
  const decision = evaluateWhatsappMessagesPersistence(
    true,
    "contact-uuid",
    { code: "23505", message: "duplicate key value" },
  );
  if (!decision.ok || !decision.duplicate) {
    throw new Error("expected duplicate durable ownership");
  }
  if (durablePersistenceFailed(true, "contact-uuid", { code: "23505" }, false)) {
    throw new Error("23505 must not be treated as persistence failure");
  }
});

Deno.test("non-23505 persistence failure blocks provider acknowledgement", () => {
  const insertError = { code: "42501", message: "permission denied" };
  const decision = evaluateWhatsappMessagesPersistence(
    true,
    "contact-uuid",
    insertError,
  );
  if (decision.ok) {
    throw new Error("expected persistence failure decision");
  }
  if (!durablePersistenceFailed(true, "contact-uuid", insertError, false)) {
    throw new Error("expected persistence failure flag");
  }
});

Deno.test("missing contact blocks durable ownership acknowledgement", () => {
  if (!durablePersistenceFailed(true, null, null, false)) {
    throw new Error("missing contact must fail closed");
  }
});

Deno.test("thrown persistence exception blocks provider acknowledgement", () => {
  if (!durablePersistenceFailed(true, "contact-uuid", null, true)) {
    throw new Error("thrown persistence must fail closed");
  }
});

Deno.test("durable ownership not required when inbound capture is skipped", () => {
  if (durablePersistenceFailed(false, null, { code: "42501" }, true)) {
    throw new Error("skipped durable path must not fail closed");
  }
});
