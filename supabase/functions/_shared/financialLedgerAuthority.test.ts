import { assertEquals } from "https://deno.land/std@0.168.0/testing/asserts.ts";
import {
  bearerToken,
  corsHeaders,
  type FinancialLedgerAuthorityDeps,
  resolveFinancialLedgerAuthority,
} from "./financialLedgerAuthority.ts";

const FINANCE_USER = "10000000-0000-4000-8000-0000000000f1";
const BUYER_USER = "20000000-0000-4000-8000-0000000000b1";
const VALID_CRON = "a".repeat(32);
const INVALID_CRON = "b".repeat(32);

function mockDeps(
  overrides: Partial<FinancialLedgerAuthorityDeps> = {},
): FinancialLedgerAuthorityDeps {
  return {
    verifyCronSecret: async (candidate) => ({
      data: candidate === VALID_CRON,
      error: null,
    }),
    getUserIdFromToken: async (token) => {
      if (token === "finance-jwt") {
        return { userId: FINANCE_USER, invalid: false };
      }
      if (token === "buyer-jwt") return { userId: BUYER_USER, invalid: false };
      return { userId: null, invalid: true };
    },
    isFinancialOperator: async (userId) => ({
      allowed: userId === FINANCE_USER,
      error: null,
    }),
    ...overrides,
  };
}

function request(headers: Record<string, string> = {}): Request {
  return new Request(
    "https://example.invalid/functions/v1/generate-bi-monthly-ledger",
    {
      method: "POST",
      headers,
    },
  );
}

Deno.test("anonymous caller without credentials is rejected", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request(),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, { ok: false, status: 401, error: "unauthorized" });
});

Deno.test("buyer JWT is rejected as forbidden", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ Authorization: "Bearer buyer-jwt" }),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, { ok: false, status: 403, error: "forbidden" });
});

Deno.test("invalid JWT is rejected as unauthorized", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ Authorization: "Bearer not-a-real-session" }),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, { ok: false, status: 401, error: "unauthorized" });
});

Deno.test("Finance-role JWT is accepted for interactive execution", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ Authorization: "Bearer finance-jwt" }),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, {
    ok: true,
    kind: "user",
    userId: FINANCE_USER,
  });
});

Deno.test("scheduled-service cron secret is accepted without a user JWT", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ "x-oasis-cron-secret": VALID_CRON }),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, { ok: true, kind: "cron", userId: null });
});

Deno.test("invalid cron secret is rejected as forbidden", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ "x-oasis-cron-secret": INVALID_CRON }),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, { ok: false, status: 403, error: "forbidden" });
});

Deno.test("cron secret verification failure fails closed", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ "x-oasis-cron-secret": VALID_CRON }),
    mockDeps({
      verifyCronSecret: async () => ({
        data: null,
        error: { message: "vault_unavailable" },
      }),
    }),
    { publicKeyAvailable: true },
  );
  assertEquals(result, {
    ok: false,
    status: 500,
    error: "authority_unavailable",
  });
});

Deno.test("finance role lookup failure fails closed", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ Authorization: "Bearer finance-jwt" }),
    mockDeps({
      isFinancialOperator: async () => ({
        allowed: null,
        error: { message: "rpc_failed" },
      }),
    }),
    { publicKeyAvailable: true },
  );
  assertEquals(result, {
    ok: false,
    status: 500,
    error: "authority_unavailable",
  });
});

Deno.test("interactive JWT path fails closed when public auth key is unavailable", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({ Authorization: "Bearer finance-jwt" }),
    mockDeps(),
    { publicKeyAvailable: false },
  );
  assertEquals(result, {
    ok: false,
    status: 500,
    error: "authority_unavailable",
  });
});

Deno.test("cron secret takes precedence over a bearer JWT", async () => {
  const result = await resolveFinancialLedgerAuthority(
    request({
      Authorization: "Bearer buyer-jwt",
      "x-oasis-cron-secret": VALID_CRON,
    }),
    mockDeps(),
    { publicKeyAvailable: true },
  );
  assertEquals(result, { ok: true, kind: "cron", userId: null });
});

Deno.test("bearerToken rejects malformed Authorization headers", () => {
  assertEquals(bearerToken(request()), null);
  assertEquals(bearerToken(request({ Authorization: "Basic abc" })), null);
  assertEquals(bearerToken(request({ Authorization: "Bearer   " })), null);
  assertEquals(
    bearerToken(request({ Authorization: "Bearer finance-jwt" })),
    "finance-jwt",
  );
});

Deno.test("cors headers expose governed cron credential header only", () => {
  const headers = corsHeaders();
  assertEquals(
    headers["Access-Control-Allow-Headers"]?.includes("x-oasis-cron-secret"),
    true,
  );
  assertEquals(
    headers["Access-Control-Allow-Headers"]?.includes("x-service-role-key"),
    false,
  );
});

Deno.test("config keeps financial functions on custom in-body authority", () => {
  const config = Deno.readTextFileSync("supabase/config.toml");
  for (const fn of ["generate-bi-monthly-ledger", "generate-rescue-ledger"]) {
    const block = `[functions.${fn}]`;
    const index = config.indexOf(block);
    if (index < 0) throw new Error(`${fn} missing from config.toml`);
    const section = config.slice(index, index + 120);
    if (!section.includes("verify_jwt = false")) {
      throw new Error(`${fn} must remain on custom in-body authority`);
    }
  }
});
