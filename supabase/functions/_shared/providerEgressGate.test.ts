import {
  guardedProviderFetch,
  isProductionProviderEgressAllowed,
  productionProviderEgressAllowed,
  PROVIDER_EGRESS_BLOCKED,
} from "./providerEgressGate.ts";

const productionUrl = "https://tcxvcatsqqertcnycuop.supabase.co";
const previewUrl = "https://stkvyotdkysieuvpuues.supabase.co";
const productionDeployment =
  "tcxvcatsqqertcnycuop_11111111-2222-4333-8444-555555555555_106";
const previewDeployment =
  "stkvyotdkysieuvpuues_11111111-2222-4333-8444-555555555555_106";

/** Assert equality without network access or external assertion modules. */
function expectEqual(actual: unknown, expected: unknown, context: string) {
  if (actual !== expected) {
    throw new Error(`${context}: expected ${String(expected)}, received ${String(actual)}`);
  }
}

Deno.test("provider gate permits only exact hosted production project identity", () => {
  expectEqual(
    isProductionProviderEgressAllowed(productionUrl, productionDeployment),
    true,
    "canonical hosted production",
  );
  const rejected: Array<[unknown, unknown]> = [
    [previewUrl, previewDeployment],
    [previewUrl, productionDeployment],
    [productionUrl, previewDeployment],
    [productionUrl, undefined],
    [productionUrl, ""],
    [productionUrl, "tcxvcatsqqertcnycuop_anything"],
    [productionUrl, "tcxvcatsqqertcnycuop_11111111-2222-4333-8444-555555555555_bad"],
    [productionUrl, "tcxvcatsqqertcnycuop_11111111-2222-4333-8444-555555555555_0"],
    [productionUrl + "/", productionDeployment],
    ["http://tcxvcatsqqertcnycuop.supabase.co", productionDeployment],
    ["http://127.0.0.1:54321", productionDeployment],
    ["https://tcxvcatsqqertcnycuop.supabase.co.attacker.invalid", productionDeployment],
    [undefined, productionDeployment],
    [null, productionDeployment],
  ];
  for (const [url, deployment] of rejected) {
    expectEqual(
      isProductionProviderEgressAllowed(url, deployment),
      false,
      "unapproved or incomplete hosted identity",
    );
  }
});

Deno.test("preview and missing-runtime identities deny without invoking fetch", async () => {
  const priorUrl = Deno.env.get("SUPABASE_URL");
  const priorDeployment = Deno.env.get("DENO_DEPLOYMENT_ID");
  let invoked = 0;
  const fakeFetch = (async () => {
    invoked += 1;
    return new Response(null, { status: 204 });
  }) as typeof fetch;

  try {
    for (const [url, deployment] of [
      [previewUrl, previewDeployment],
      [previewUrl, productionDeployment],
      [productionUrl, previewDeployment],
      [productionUrl, ""],
      ["", ""],
    ]) {
      Deno.env.set("SUPABASE_URL", url);
      Deno.env.set("DENO_DEPLOYMENT_ID", deployment);
      expectEqual(productionProviderEgressAllowed(), false, "preview deny");
      let blocked = false;
      try {
        await guardedProviderFetch("https://api.resend.com/emails", {
          method: "POST",
          headers: { Authorization: "Bearer synthetic-secret" },
        }, fakeFetch);
      } catch (error) {
        blocked = error instanceof Error &&
          error.message === PROVIDER_EGRESS_BLOCKED;
      }
      expectEqual(blocked, true, "blocked before outbound");
      expectEqual(invoked, 0, "no external provider request");
    }
  } finally {
    if (priorUrl === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", priorUrl);
    if (priorDeployment === undefined) Deno.env.delete("DENO_DEPLOYMENT_ID");
    else Deno.env.set("DENO_DEPLOYMENT_ID", priorDeployment);
  }
});

Deno.test("production-shaped hosted identity allows only injected stub fetch", async () => {
  const priorUrl = Deno.env.get("SUPABASE_URL");
  const priorDeployment = Deno.env.get("DENO_DEPLOYMENT_ID");
  let invoked = 0;
  try {
    Deno.env.set("SUPABASE_URL", productionUrl);
    Deno.env.set("DENO_DEPLOYMENT_ID", productionDeployment);
    const result = await guardedProviderFetch(
      "https://api.resend.com/emails",
      { method: "POST" },
      (async () => {
        invoked += 1;
        return new Response(null, { status: 204 });
      }) as typeof fetch,
    );
    expectEqual(result.status, 204, "injected stub response");
    expectEqual(invoked, 1, "production-shaped identity permits stub fetch");
  } finally {
    if (priorUrl === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", priorUrl);
    if (priorDeployment === undefined) Deno.env.delete("DENO_DEPLOYMENT_ID");
    else Deno.env.set("DENO_DEPLOYMENT_ID", priorDeployment);
  }
});

Deno.test("notify-event source wraps all three outbound provider calls and denies before DB access", async () => {
  const url = new URL("../notify-event/index.ts", import.meta.url);
  const source = await Deno.readTextFile(url);
  const wrapped = source.match(/await guardedProviderFetch\(/g) ?? [];
  const raw = source.match(/await fetch\(/g) ?? [];
  expectEqual(wrapped.length, 3, "all known provider endpoints wrapped");
  expectEqual(raw.length, 0, "no unguarded outbound call");
  const denyIndex = source.indexOf("if (!productionProviderEgressAllowed())");
  const authIndex = source.indexOf("const authorization = await requireInternalStaff(");
  const insertIndex = source.indexOf('await admin.from("audit_logs").insert(');
  expectEqual(denyIndex > 0 && denyIndex < authIndex, true, "deny before auth/database");
  expectEqual(denyIndex < insertIndex, true, "deny before audit side effect");
  expectEqual(
    source.includes('return json({ error: "provider_egress_disabled" }, 503)'),
    true,
    "opaque 503 for preview callers",
  );
});
