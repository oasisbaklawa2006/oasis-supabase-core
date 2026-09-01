import {
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import { sha256Hex } from "./hash.ts";
import {
  corpusEntitySalt,
  legacyCorpusEntitySalt,
  protectedHarnessNamespace,
} from "./core_runner.ts";

/** Pair that collides under the legacy `% 9000` salt reduction. */
const LEGACY_COLLIDING_HASH_PAIR = ["corpus-100", "synthetic-224"] as const;

Deno.test("sha256Hex is deterministic for protected corpus bytes", async () => {
  const value = '{"corpus":"historical-demo","cases":[]}';
  const first = await sha256Hex(value);
  const second = await sha256Hex(value);
  assertEquals(first, second);
  assertEquals(first.length, 64);
});

Deno.test("protected harness namespace uses content hash not corpus label", async () => {
  const label = "historical-abc123def456";
  const raw = '{"corpus":"historical-abc123def456","cases":[]}';
  const contentHash = await sha256Hex(raw);

  const fromLabel = protectedHarnessNamespace(label);
  const fromHash = protectedHarnessNamespace(contentHash);
  assertNotEquals(fromLabel.salt, fromHash.salt);
  assertNotEquals(fromLabel.entityId, fromHash.entityId);
  assertNotEquals(corpusEntitySalt(label), corpusEntitySalt(contentHash));
});

Deno.test("protected execution boundary separates legacy % 9000 collision pair", () => {
  const [hashA, hashB] = LEGACY_COLLIDING_HASH_PAIR;
  assertEquals(legacyCorpusEntitySalt(hashA), legacyCorpusEntitySalt(hashB));

  const namespaceA = protectedHarnessNamespace(hashA);
  const namespaceB = protectedHarnessNamespace(hashB);
  assertNotEquals(namespaceA.salt, namespaceB.salt);
  assertNotEquals(namespaceA.entityId, namespaceB.entityId);
});
