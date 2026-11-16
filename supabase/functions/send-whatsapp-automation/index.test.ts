import { dispatchOrderAutomation, resolveSafeSenderUrl } from "./index.ts";

function assertSame(actual: unknown, expected: unknown, label: string) {
  if (actual !== expected) {
    throw new Error(
      `${label}: expected=${String(expected)}, actual=${String(actual)}`,
    );
  }
}

function makeAdmin(claimed: boolean) {
  let claims = 0;
  let updates = 0;
  let saved: Record<string, unknown> | null = null;
  let claimArgs: Record<string, unknown> | null = null;
  const admin = {
    async rpc(name: string, args: Record<string, unknown>) {
      await Promise.resolve();
      claims++;
      claimArgs = args;
      if (name !== "claim_legacy_whatsapp_automation_v1") {
        throw new Error("unexpected RPC");
      }
      return {
        data: {
          claimed,
          automation_id: "55550000-0000-0000-0000-000000000007",
          status: "pending",
        },
        error: null,
      };
    },
    from(table: string) {
      if (table !== "whatsapp_automations") throw new Error("unexpected table");
      return {
        update(changes: Record<string, unknown>) {
          updates++;
          saved = changes;
          const query = {
            eq(_key: string, _value: unknown) {
              return query;
            },
            then(resolve: (value: { error: null }) => unknown) {
              return Promise.resolve({ error: null }).then(resolve);
            },
          };
          return query;
        },
      };
    },
  };
  return {
    admin,
    get claims() {
      return claims;
    },
    get updates() {
      return updates;
    },
    get saved() {
      return saved;
    },
    get claimArgs() {
      return claimArgs;
    },
  };
}

Deno.test("service-role sender URL is confined to same-origin exact function", () => {
  const base = "https://tcxvcatsqqertcnycuop.supabase.co";
  const expected = base + "/functions/v1/send-whatsapp";
  assertSame(resolveSafeSenderUrl(base, null), expected, "canonical function");
  assertSame(resolveSafeSenderUrl(base, expected), expected, "safe override");
  assertSame(resolveSafeSenderUrl(base, "https://attacker.invalid/collect"), null, "external host rejected");
  assertSame(resolveSafeSenderUrl(base, "https://tcxvcatsqqertcnycuop.supabase.co.evil.invalid/functions/v1/send-whatsapp"), null, "lookalike host rejected");
  assertSame(resolveSafeSenderUrl(base, expected + "?token=leak"), null, "query rejected");
  assertSame(resolveSafeSenderUrl(base, base + "/functions/v1/other"), null, "other function rejected");
  assertSame(resolveSafeSenderUrl("http://127.0.0.1:54321", null), null, "plaintext project URL rejected");
  assertSame(resolveSafeSenderUrl(null, null), null, "missing project URL rejected");
});

Deno.test("duplicate durable claim suppresses provider send", async () => {
  const h = makeAdmin(false);
  let sends = 0;
  const sender = async () => {
    await Promise.resolve();
    sends++;
    return { success: true, messageId: "wamid.UNEXPECTED" };
  };
  await dispatchOrderAutomation(
    h.admin as never,
    "55550000-0000-0000-0000-000000000001",
    "so_created",
    "so_confirmation",
    "9800000000",
    "Fixture",
    undefined,
    sender,
  );
  assertSame(h.claims, 1, "one durable claim lookup");
  assertSame(sends, 0, "duplicate never calls provider");
  assertSame(h.updates, 0, "duplicate leaves immutable receipt");
  assertSame(h.claimArgs?.p_phone_digits, "919800000000", "normalized phone");
});

Deno.test("new order event sends once and records sent not delivered", async () => {
  const h = makeAdmin(true);
  let sends = 0;
  const sender = async () => {
    await Promise.resolve();
    sends++;
    return { success: true, messageId: "wamid.ACCEPTED_FIXTURE" };
  };
  await dispatchOrderAutomation(
    h.admin as never,
    "55550000-0000-0000-0000-000000000001",
    "payment_verified",
    "payment_confirmed",
    "919800000000",
    "Fixture",
    "55550000-0000-0000-0000-000000000002",
    sender,
  );
  assertSame(sends, 1, "one provider send");
  assertSame(h.updates, 1, "one status update");
  assertSame(h.saved?.status, "sent", "provider acceptance only");
  assertSame(
    h.saved?.provider_message_id,
    "wamid.ACCEPTED_FIXTURE",
    "provider correlation ID",
  );
});

Deno.test("uncertain provider outcome never becomes failed or delivered", async () => {
  const h = makeAdmin(true);
  let sends = 0;
  const sender = async () => {
    await Promise.resolve();
    sends++;
    return {
      success: false,
      acceptanceUnknown: true,
      error: "ACCEPTANCE_UNKNOWN",
    };
  };
  await dispatchOrderAutomation(
    h.admin as never,
    "55550000-0000-0000-0000-000000000001",
    "production_started",
    "production_alert",
    "919800000000",
    "Fixture",
    undefined,
    sender,
  );
  assertSame(sends, 1, "one attempt");
  assertSame(
    h.saved?.status,
    "acceptance_unknown",
    "quarantine unknown acceptance",
  );
  assertSame(h.saved?.provider_message_id, null, "no invented provider ID");
});

Deno.test("invalid phone fails before any durable claim or send", async () => {
  const h = makeAdmin(true);
  let sends = 0;
  const sender = async () => {
    await Promise.resolve();
    sends++;
    return { success: true };
  };
  let thrown = false;
  try {
    await dispatchOrderAutomation(
      h.admin as never,
      "55550000-0000-0000-0000-000000000001",
      "order_dispatched",
      "dispatch_alert",
      "bad-phone",
      "Fixture",
      undefined,
      sender,
    );
  } catch {
    thrown = true;
  }
  assertSame(thrown, true, "invalid phone rejected");
  assertSame(h.claims, 0, "no DB claim");
  assertSame(sends, 0, "no provider attempt");
});

Deno.test("legacy automation has no local default and no null contact insertion", async () => {
  const source = await Deno.readTextFile(
    new URL("./index.ts", import.meta.url),
  );
  if (source.includes("http://localhost:54321/functions/v1/send-whatsapp")) {
    throw new Error("local URL must never be production fallback");
  }
  if (
    source.includes("contact_id: null") || source.includes("recordAutomation(")
  ) {
    throw new Error("bad post-send ledger insert remains");
  }
  if (!source.includes("claim_legacy_whatsapp_automation_v1")) {
    throw new Error("missing durable pre-send claim");
  }
});
