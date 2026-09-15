import {
  allowedOrigin,
  decodeJwtAal,
  findExistingUserAcrossPages,
  generateStrongPassword,
  parseRequest,
  stepUpBlocksGrant,
} from "./adminProvisionUser.ts";

const assert: (condition: unknown, message?: string) => asserts condition = (
  condition,
  message = "assertion failed",
) => {
  if (!condition) throw new Error(message);
};

const assertThrows = (fn: () => unknown, pattern: RegExp) => {
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
};

const encodeBase64Url = (obj: unknown): string => {
  const base64 = btoa(JSON.stringify(obj));
  return base64.replaceAll("+", "-").replaceAll("/", "_").replace(/[=]+$/, "");
};

Deno.test("parseRequest accepts a well-formed request and defaults mode to invite", () => {
  const parsed = parseRequest({
    email: "  qa-rgs@example.invalid  ",
    roleKey: " rgs_admin ",
  });
  assert(parsed.email === "qa-rgs@example.invalid");
  assert(parsed.roleKey === "rgs_admin");
  assert(parsed.mode === "invite");
});

Deno.test("parseRequest honours an explicit service_credential mode", () => {
  const parsed = parseRequest({
    email: "qa@example.invalid",
    roleKey: "tv_ready",
    mode: "service_credential",
  });
  assert(parsed.mode === "service_credential");
});

Deno.test("parseRequest rejects an unrecognised mode before provisioning", () => {
  assertThrows(
    () =>
      parseRequest({
        email: "qa@example.invalid",
        roleKey: "tv_ready",
        mode: "superuser",
      }),
    /mode must be "invite" or "service_credential"/,
  );
});

Deno.test("parseRequest rejects a missing or malformed email", () => {
  assertThrows(() => parseRequest({ roleKey: "rgs_admin" }), /email/);
  assertThrows(
    () => parseRequest({ email: "not-an-email", roleKey: "rgs_admin" }),
    /email/,
  );
  assertThrows(
    () => parseRequest({ email: "  ", roleKey: "rgs_admin" }),
    /email/,
  );
});

Deno.test("parseRequest rejects a missing roleKey", () => {
  assertThrows(() => parseRequest({ email: "qa@example.invalid" }), /roleKey/);
  assertThrows(
    () => parseRequest({ email: "qa@example.invalid", roleKey: "  " }),
    /roleKey/,
  );
});

Deno.test("parseRequest rejects a non-object body", () => {
  assertThrows(() => parseRequest(null), /JSON object/);
  assertThrows(() => parseRequest("a string"), /JSON object/);
  assertThrows(() => parseRequest(42), /JSON object/);
});

Deno.test("findExistingUserAcrossPages finds an identity beyond the first 1,000 users", async () => {
  const firstPage = Array.from({ length: 1000 }, (_, index) => ({
    id: `user-${index}`,
    email: `user-${index}@example.invalid`,
  }));
  const visitedPages: number[] = [];

  const found = await findExistingUserAcrossPages(
    "TARGET@example.invalid",
    (page, perPage) => {
      visitedPages.push(page);
      assert(perPage === 1000, `unexpected perPage: ${perPage}`);
      if (page === 1) return Promise.resolve({ users: firstPage, total: 1001 });
      if (page === 2) {
        return Promise.resolve({
          users: [{ id: "target-id", email: "target@example.invalid" }],
          total: 1001,
        });
      }
      throw new Error(`unexpected page ${page}`);
    },
  );

  assert(found?.id === "target-id");
  assert(visitedPages.join(",") === "1,2");
});

Deno.test("findExistingUserAcrossPages stops at the reported exact-page total", async () => {
  const firstPage = Array.from({ length: 1000 }, (_, index) => ({
    id: `user-${index}`,
    email: `user-${index}@example.invalid`,
  }));
  let calls = 0;

  const found = await findExistingUserAcrossPages(
    "missing@example.invalid",
    (page) => {
      calls += 1;
      assert(page === 1, `unexpected page ${page}`);
      return Promise.resolve({ users: firstPage, total: 1000 });
    },
  );

  assert(found === null);
  assert(calls === 1);
});

Deno.test("stepUpBlocksGrant mirrors SQL has_step_up_auth for privileged provisioning", () => {
  assert(
    stepUpBlocksGrant(true, "aal1") ===
      "this role requires a step-up (AAL2) session on the granting admin",
  );
  assert(
    stepUpBlocksGrant(true, undefined) ===
      "this role requires a step-up (AAL2) session on the granting admin",
  );
  assert(stepUpBlocksGrant(true, "aal2") === null);
  assert(stepUpBlocksGrant(false, "aal1") === null);
  assert(stepUpBlocksGrant(false, undefined) === null);
});

Deno.test("decodeJwtAal reads the aal claim from a well-formed JWT", () => {
  const token = `${encodeBase64Url({ alg: "HS256" })}.${
    encodeBase64Url({ sub: "u1", aal: "aal2" })
  }.signature`;
  assert(decodeJwtAal(token) === "aal2");
});

Deno.test("decodeJwtAal returns undefined for a token missing the aal claim", () => {
  const token = `${encodeBase64Url({ alg: "HS256" })}.${
    encodeBase64Url({ sub: "u1" })
  }.signature`;
  assert(decodeJwtAal(token) === undefined);
});

Deno.test("decodeJwtAal returns undefined (never throws) for a malformed token", () => {
  assert(decodeJwtAal("not-a-jwt") === undefined);
  assert(decodeJwtAal("only.two") === undefined);
  assert(decodeJwtAal("") === undefined);
  assert(decodeJwtAal("a.b.c") === undefined); // valid shape, invalid base64/JSON payload
});

Deno.test("generateStrongPassword produces sufficiently long, non-repeating, URL-safe output", () => {
  const passwordOne = generateStrongPassword();
  const passwordTwo = generateStrongPassword();
  assert(passwordOne.length >= 24, `password too short: ${passwordOne.length}`);
  assert(passwordOne !== passwordTwo, "two generated passwords collided");
  assert(
    !/[+/=]/.test(passwordOne),
    "password is not base64url (contains +, / or =)",
  );
});

Deno.test("allowedOrigin only matches an exact configured origin", () => {
  assert(
    allowedOrigin(
      "https://b2b.oasisbaklawa.com",
      "https://b2b.oasisbaklawa.com",
    ) === "https://b2b.oasisbaklawa.com",
  );
  assert(
    allowedOrigin(
      "https://b2b.oasisbaklawa.com",
      "https://attacker.example",
    ) === null,
  );
  assert(allowedOrigin("https://b2b.oasisbaklawa.com", null) === null);
  assert(allowedOrigin(undefined, "https://b2b.oasisbaklawa.com") === null);
  assert(allowedOrigin("", "https://b2b.oasisbaklawa.com") === null);
});
