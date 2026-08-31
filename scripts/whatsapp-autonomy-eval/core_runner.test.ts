import {
  assertEquals,
  assertNotEquals,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  CASE_ID_STRIDE,
  CORPUS_SALT_BUCKETS,
  CORPUS_SALT_STRIDE,
  corpusEntitySalt,
  harnessEntityId,
  legacyCorpusEntitySalt,
  PROTECTED_INBOUND_CONFLICT_CLAUSE,
  STAGE2_MAX_CASE_INDEX,
} from "./core_runner.ts";

const STAGE2_CASE_RANGE = 8911;
const ENTITY_KINDS = [1, 2, 3, 4] as const;
/** Pair that collides under the legacy `% 9000` salt reduction. */
const LEGACY_COLLIDING_HASH_PAIR = ["corpus-100", "synthetic-224"] as const;

Deno.test("legacy % 9000 salt collisions are separated by collision-resistant namespace", () => {
  const [hashA, hashB] = LEGACY_COLLIDING_HASH_PAIR;
  assertEquals(legacyCorpusEntitySalt(hashA), legacyCorpusEntitySalt(hashB));
  assertNotEquals(corpusEntitySalt(hashA), corpusEntitySalt(hashB));
  assertNotEquals(
    harnessEntityId("protected", 0, 2, hashA),
    harnessEntityId("protected", 0, 2, hashB),
  );
});

Deno.test("protected corpus salts cannot collide across Stage-2 case range", () => {
  const hashes = [
    "ae6b6bfecfdce8b6873a650815d14e3d2f929ef1e47ddf880397357d36c2f0c9",
    "0000000000000000000000000000000000000000000000000000000000000001",
    "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff",
    "corpus-hash-b",
    "corpus-hash-c",
    ...LEGACY_COLLIDING_HASH_PAIR,
  ];
  const salts = new Set(hashes.map((hash) => corpusEntitySalt(hash)));
  assertEquals(salts.size, hashes.length);

  const seen = new Set<string>();
  for (const hash of hashes) {
    for (let caseIndex = 0; caseIndex < STAGE2_CASE_RANGE; caseIndex += 137) {
      for (const kind of ENTITY_KINDS) {
        const id = harnessEntityId("protected", caseIndex, kind, hash);
        assertEquals(seen.has(id), false, `duplicate protected id at ${hash}`);
        seen.add(id);
      }
    }
  }
});

Deno.test("protected entity IDs do not overlap sanitized IDs at Stage-2 scale", () => {
  const protectedHash =
    "ae6b6bfecfdce8b6873a650815d14e3d2f929ef1e47ddf880397357d36c2f0c9";
  const sanitizedIds = new Set<string>();
  for (let caseIndex = 0; caseIndex < STAGE2_CASE_RANGE; caseIndex += 53) {
    for (const kind of ENTITY_KINDS) {
      sanitizedIds.add(harnessEntityId("sanitized", caseIndex, kind));
    }
  }

  for (let caseIndex = 0; caseIndex < STAGE2_CASE_RANGE; caseIndex += 53) {
    for (const kind of ENTITY_KINDS) {
      const protectedId = harnessEntityId(
        "protected",
        caseIndex,
        kind,
        protectedHash,
      );
      assertEquals(
        sanitizedIds.has(protectedId),
        false,
        `protected/sanitized collision at case ${caseIndex}`,
      );
    }
  }
});

Deno.test("salt stride exceeds maximum case-index contribution", () => {
  const maxCaseContribution = STAGE2_MAX_CASE_INDEX * CASE_ID_STRIDE;
  assertEquals(maxCaseContribution < CORPUS_SALT_STRIDE, true);
  assertEquals(CORPUS_SALT_BUCKETS > 9000, true);
});

Deno.test("distinct salts cannot produce identical entity IDs at same case index", () => {
  const saltA = corpusEntitySalt("hash-alpha");
  const saltB = corpusEntitySalt("hash-beta");
  assertNotEquals(saltA, saltB);

  const idA = harnessEntityId("protected", 0, 2, "hash-alpha");
  const idB = harnessEntityId("protected", 0, 2, "hash-beta");
  assertNotEquals(idA, idB);
});

Deno.test("protected inbound conflict preserves primary key on provider replay", () => {
  assertEquals(
    PROTECTED_INBOUND_CONFLICT_CLAUSE.includes("id = excluded.id"),
    false,
  );
  assertEquals(
    /\bid\s*=\s*excluded\.id\b/i.test(PROTECTED_INBOUND_CONFLICT_CLAUSE),
    false,
  );
  assertEquals(
    PROTECTED_INBOUND_CONFLICT_CLAUSE.includes(
      "sender_phone = excluded.sender_phone",
    ),
    true,
  );
  assertEquals(
    PROTECTED_INBOUND_CONFLICT_CLAUSE.includes(
      "message_body = excluded.message_body",
    ),
    true,
  );
  assertEquals(
    PROTECTED_INBOUND_CONFLICT_CLAUSE.includes(
      "message_type = excluded.message_type",
    ),
    true,
  );
});

Deno.test("runSanitizedCases forwards corpusHash to executeGoldenCase", () => {
  const src = Deno.readTextFileSync(
    new URL("./core_runner.ts", import.meta.url),
  );
  assertEquals(
    /executeGoldenCase\(\s*sql,\s*testCase,\s*index \+ 1,\s*corpus,\s*corpusHash,\s*\)/
      .test(src),
    true,
  );
});

Deno.test("run_protected propagates corpus identity into protected execution", () => {
  const src = Deno.readTextFileSync(
    new URL("./run_protected.ts", import.meta.url),
  );
  assertEquals(
    /runSanitizedCases\([\s\S]*cases,[\s\S]*"protected",[\s\S]*corpus[\s\S]*\)/
      .test(
        src,
      ),
    true,
  );
});
