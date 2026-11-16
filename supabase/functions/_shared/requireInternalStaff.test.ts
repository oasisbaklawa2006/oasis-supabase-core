import { matchesServiceRoleToken } from "./requireInternalStaff.ts";

function assert(result: boolean, description: string): void {
  if (!result) throw new Error(description);
}

Deno.test("service-role comparison accepts exact token only", async () => {
  const secret = "WA100_TEST_ONLY_SERVICE_TOKEN_0123456789";
  assert(await matchesServiceRoleToken(secret, secret), "exact token rejected");
});

Deno.test("service-role comparison rejects prefixes and suffixes", async () => {
  const secret = "WA100_TEST_ONLY_SERVICE_TOKEN_0123456789";
  const invalid = [
    "WA100_TEST_ONLY_SERVICE_TOKEN_012345678",
    "WA100_TEST_ONLY_SERVICE_TOKEN_01234567890",
    "WA100_TEST_ONLY_SERVICE_TOKEN_012345678X",
    "X" + secret.slice(1),
    "",
  ];
  for (const candidate of invalid) {
    assert(
      !(await matchesServiceRoleToken(candidate, secret)),
      "a mismatched token was accepted",
    );
  }
});

Deno.test("service-role comparison respects exact UTF-8 bytes", async () => {
  const secret = "WA100_TEST_ONLY_\u00e9";
  assert(
    await matchesServiceRoleToken(secret, secret),
    "identical UTF-8 input rejected",
  );
  assert(
    !(await matchesServiceRoleToken("WA100_TEST_ONLY_e", secret)),
    "different UTF-8 input accepted",
  );
});
