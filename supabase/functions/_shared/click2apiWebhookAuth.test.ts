import {
  authenticateClick2ApiWebhook,
  matchesWebhookToken,
} from "./click2apiWebhookAuth.ts";

Deno.test("query echo token authenticates Click2API callback", () => {
  const req = new Request("https://example.test/functions/v1/whatsapp-webhook?echo=expected");
  const result = authenticateClick2ApiWebhook(req, undefined, "expected");
  if (!result.authenticated || result.source !== "query") throw new Error("query token rejected");
});

Deno.test("header secret authenticates before query fallback", () => {
  const req = new Request("https://example.test/functions/v1/whatsapp-webhook?echo=wrong", {
    headers: { "x-webhook-secret": "header-secret" },
  });
  const result = authenticateClick2ApiWebhook(req, "header-secret", "expected");
  if (!result.authenticated || result.source !== "header") throw new Error("header secret rejected");
});

Deno.test("missing or invalid credentials fail closed", () => {
  const req = new Request("https://example.test/functions/v1/whatsapp-webhook?echo=wrong");
  const result = authenticateClick2ApiWebhook(req, "header-secret", "expected");
  if (result.authenticated || result.source !== null) throw new Error("invalid credentials accepted");
});

Deno.test("challenge token comparison is exact", () => {
  if (!matchesWebhookToken("expected", "expected")) throw new Error("valid token rejected");
  if (matchesWebhookToken("expected-x", "expected")) throw new Error("invalid token accepted");
});
