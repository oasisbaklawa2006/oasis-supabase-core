import { assertStringIncludes } from "https://deno.land/std@0.168.0/testing/asserts.ts";

Deno.test("provider migration branch documents incomplete worker integration", async () => {
  const text = await Deno.readTextFile(new URL("./README.provider-migration.md", import.meta.url));
  assertStringIncludes(text, "must not be considered migrated");
  assertStringIncludes(text, "must not be merged or deployed");
});
