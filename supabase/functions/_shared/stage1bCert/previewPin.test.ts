import {
  assertOrchestratorPreviewUrl,
  assertPreviewCertRuntime,
} from "./previewPin.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) {
    throw new Error(`expected ${String(expected)}, received ${String(actual)}`);
  }
}

function assertThrows(fn: () => unknown, message: string): void {
  try {
    fn();
  } catch (error) {
    if (error instanceof Error && error.message.includes(message)) return;
    throw new Error(`unexpected error: ${String(error)}`);
  }
  throw new Error(`expected error containing ${message}`);
}

function withSupabaseUrl(url: string | undefined, fn: () => void): void {
  const prior = Deno.env.get("SUPABASE_URL");
  if (url === undefined) Deno.env.delete("SUPABASE_URL");
  else Deno.env.set("SUPABASE_URL", url);
  try {
    fn();
  } finally {
    if (prior === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", prior);
  }
}

Deno.test("current PR preview ref is accepted dynamically", () => {
  withSupabaseUrl("https://evmeoljyrvfiidxqzpya.supabase.co", () => {
    assertEquals(assertPreviewCertRuntime().projectRef, "evmeoljyrvfiidxqzpya");
  });
});

Deno.test("production preview authority remains rejected", () => {
  withSupabaseUrl("https://tcxvcatsqqertcnycuop.supabase.co", () => {
    assertThrows(
      () => assertPreviewCertRuntime(),
      "PREVIEW_PIN_FAILED:PRODUCTION_REF_FORBIDDEN",
    );
  });
});

Deno.test("orchestrator must match the runtime preview authority", () => {
  assertOrchestratorPreviewUrl(
    "https://evmeoljyrvfiidxqzpya.supabase.co",
    "evmeoljyrvfiidxqzpya",
  );
  assertThrows(
    () =>
      assertOrchestratorPreviewUrl(
        "https://otherpreview1234567.supabase.co",
        "evmeoljyrvfiidxqzpya",
      ),
    "ORCHESTRATOR_PREVIEW_REJECTED",
  );
  assertThrows(
    () =>
      assertOrchestratorPreviewUrl(
        "https://tcxvcatsqqertcnycuop.supabase.co",
        "tcxvcatsqqertcnycuop",
      ),
    "ORCHESTRATOR_PREVIEW_REJECTED:production_forbidden",
  );
});
