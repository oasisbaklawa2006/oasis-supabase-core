import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.168.0/testing/asserts.ts";
import {
  authorizePreviewCertRequest,
  resolvePreviewCertBearerToken,
} from "./previewCertAuth.ts";

function withEnv(
  values: Record<string, string | undefined>,
  fn: () => void,
): void {
  const prior = new Map<string, string | undefined>();
  for (const [key, value] of Object.entries(values)) {
    prior.set(key, Deno.env.get(key));
    if (value === undefined) Deno.env.delete(key);
    else Deno.env.set(key, value);
  }
  try {
    fn();
  } finally {
    for (const [key, value] of prior.entries()) {
      if (value === undefined) Deno.env.delete(key);
      else Deno.env.set(key, value);
    }
  }
}

Deno.test("A: missing WA_STAGE1B_CERT_SECRET fails closed", () => {
  withEnv({ WA_STAGE1B_CERT_SECRET: undefined }, () => {
    assertThrows(
      () => resolvePreviewCertBearerToken(),
      Error,
      "WA_STAGE1B_CERT_SECRET_REQUIRED",
    );
    assertEquals(
      authorizePreviewCertRequest(
        new Request("http://local", {
          headers: { Authorization: "Bearer anything" },
        }),
      ),
      false,
    );
  });
});

Deno.test("B: GEMINI present but WA_STAGE1B_CERT_SECRET missing still fails closed", () => {
  withEnv({
    GEMINI_API_KEY: "gemini-provider-key",
    WA_STAGE1B_CERT_SECRET: undefined,
  }, () => {
    assertThrows(
      () => resolvePreviewCertBearerToken(),
      Error,
      "WA_STAGE1B_CERT_SECRET_REQUIRED",
    );
    assertEquals(
      authorizePreviewCertRequest(
        new Request("http://local", {
          headers: { Authorization: "Bearer gemini-provider-key" },
        }),
      ),
      false,
    );
  });
});

Deno.test("C: wrong cert bearer is rejected", () => {
  withEnv({ WA_STAGE1B_CERT_SECRET: "independent-cert-secret" }, () => {
    assertEquals(
      authorizePreviewCertRequest(
        new Request("http://local", {
          headers: { Authorization: "Bearer wrong-bearer" },
        }),
      ),
      false,
    );
  });
});

Deno.test("D: correct independent cert bearer is accepted", () => {
  withEnv({ WA_STAGE1B_CERT_SECRET: "independent-cert-secret" }, () => {
    assertEquals(
      authorizePreviewCertRequest(
        new Request("http://local", {
          headers: { Authorization: "Bearer independent-cert-secret" },
        }),
      ),
      true,
    );
    assertEquals(resolvePreviewCertBearerToken(), "independent-cert-secret");
  });
});

Deno.test("E: GEMINI credential cannot substitute for certification auth", () => {
  withEnv({
    GEMINI_API_KEY: "gemini-provider-key",
    WA_STAGE1B_CERT_SECRET: "independent-cert-secret",
  }, () => {
    assertEquals(
      authorizePreviewCertRequest(
        new Request("http://local", {
          headers: { Authorization: "Bearer gemini-provider-key" },
        }),
      ),
      false,
    );
  });
});

Deno.test("F: production project ref remains rejected by sync workflow guard", () => {
  const workflow = Deno.readTextFileSync(
    ".github/workflows/sync-preview-cert-edge-secrets.yml",
  );
  assertEquals(
    workflow.includes("PRODUCTION_PROJECT_REF: tcxvcatsqqertcnycuop"),
    true,
  );
  assertEquals(
    workflow.includes('if [[ "$ref" == "$PRODUCTION_PROJECT_REF" ]]; then'),
    true,
  );
});
