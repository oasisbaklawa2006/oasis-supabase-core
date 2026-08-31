import {
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { sha256Hex } from "./hash.ts";
import { corpusEntitySalt } from "./core_runner.ts";

Deno.test("sha256Hex is deterministic for protected corpus bytes", async () => {
  const value = '{"corpus":"historical-demo","cases":[]}';
  const first = await sha256Hex(value);
  const second = await sha256Hex(value);
  assertEquals(first, second);
  assertEquals(first.length, 64);
});

Deno.test("protected namespace uses content hash not corpus label", () => {
  const label = "historical-abc123def456";
  const contentHash =
    "ae6b6bfecfdce8b6873a650815d14e3d2f929ef1e47ddf880397357d36c2f0c9";
  assertNotEquals(corpusEntitySalt(label), corpusEntitySalt(contentHash));
});
