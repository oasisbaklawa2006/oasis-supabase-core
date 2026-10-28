import {
  durablePersistenceFailed,
  evaluateWhatsappMessagesPersistence,
  INBOUND_COMPLETION_DIRECTION,
  inboundMediaObjectName,
  isStorageObjectExistsError,
  stableInboundBufferUuid,
  stableInboundEffectUuid,
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

Deno.test("buffer key is byte-compatible with rows written before effect keys existed", async () => {
  // Golden value produced by the original buffer-only helper; changing it would let a replay
  // insert a second buffer row for a message that already has one.
  const golden = "88d7bd35-f74d-8e74-8e91-c6263d65dcbd";
  if (await stableInboundBufferUuid("wamid.GOLDEN_FIXTURE_001") !== golden) {
    throw new Error("buffer key changed");
  }
  if (await stableInboundEffectUuid("buffer", "  wamid.GOLDEN_FIXTURE_001  ") !== golden) {
    throw new Error("buffer key must ignore surrounding whitespace");
  }
});

Deno.test("effect keys are deterministic, UUIDv8-shaped and distinct per effect and message", async () => {
  const kinds = ["buffer", "dispute", "interaction", "media"] as const;
  const seen = new Set<string>();
  for (const kind of kinds) {
    for (const wamid of ["wamid.A", "wamid.B"]) {
      const first = await stableInboundEffectUuid(kind, wamid);
      const again = await stableInboundEffectUuid(kind, wamid);
      if (first !== again) throw new Error(`${kind} key is not deterministic`);
      if (!/^[0-9a-f]{8}-[0-9a-f]{4}-8[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/.test(first)) {
        throw new Error(`${kind} key is not a UUIDv8: ${first}`);
      }
      if (first.includes("wamid")) throw new Error("key must not embed the provider id");
      seen.add(first);
    }
  }
  if (seen.size !== kinds.length * 2) throw new Error("keys must be unique per effect and message");
});

Deno.test("effect keys require a provider message id", async () => {
  for (const kind of ["buffer", "dispute", "interaction", "media"] as const) {
    let threw = false;
    try {
      await stableInboundEffectUuid(kind, "   ");
    } catch {
      threw = true;
    }
    if (!threw) throw new Error(`${kind} key must reject a blank provider id`);
  }
});

Deno.test("media object name is stable per message, sender-scoped and carries the extension", async () => {
  const name = await inboundMediaObjectName("9876543210", "wamid.MEDIA", "pdf");
  if (name !== await inboundMediaObjectName("9876543210", "wamid.MEDIA", "pdf")) {
    throw new Error("media object name must be deterministic");
  }
  if (!/^9876543210\/[0-9a-f-]{36}\.pdf$/.test(name)) throw new Error(`unexpected media object name ${name}`);
  if (name === await inboundMediaObjectName("9876543210", "wamid.OTHER", "pdf")) {
    throw new Error("different messages must not share an object");
  }
});

Deno.test("storage 'already exists' is recognised so a replayed upload counts as stored", () => {
  if (!isStorageObjectExistsError({ statusCode: "409", message: "The resource already exists" })) {
    throw new Error("409 must be treated as already stored");
  }
  if (!isStorageObjectExistsError({ message: "Duplicate" })) throw new Error("duplicate message");
  if (isStorageObjectExistsError({ statusCode: "500", message: "internal error" })) {
    throw new Error("a real storage failure must not be treated as stored");
  }
  if (isStorageObjectExistsError(null)) throw new Error("no error is not an exists error");
});

Deno.test("completion receipts use a direction no other debug_webhooks writer uses", () => {
  for (const other of ["inbound", "outbound", "provider_status_unmatched"]) {
    if (INBOUND_COMPLETION_DIRECTION === other) throw new Error("receipt direction collides");
  }
});
