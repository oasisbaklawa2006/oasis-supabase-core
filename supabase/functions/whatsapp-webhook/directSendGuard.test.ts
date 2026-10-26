/** Regression: no webhook-owned unsanctioned Click2API sender may reappear. */
Deno.test("webhook delegates all customer replies to the governed outbox", async () => {
  const source = await Deno.readTextFile(new URL("./index.ts", import.meta.url));
  if (source.includes("crm.click2api.in/api/v1/messages")) {
    throw new Error("WA_LEGACY_DIRECT_SEND_BYPASS: webhook contains direct provider POST");
  }
  if (!source.includes("WA_LEGACY_DIRECT_SEND_FORBIDDEN_USE_GOVERNED_OUTBOX")) {
    throw new Error("legacy send helper no longer fails closed");
  }
  if (!source.includes("const waAutoOrderWritesEnabled = false;")) {
    throw new Error("old commercial webhook authoring unexpectedly reenabled");
  }
});
