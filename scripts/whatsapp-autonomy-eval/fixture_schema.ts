import type { GoldenCase } from "./types.ts";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireString(
  value: unknown,
  path: string,
): string {
  if (typeof value !== "string" || value.trim() === "") {
    throw new Error(`${path} must be a non-empty string`);
  }
  return value;
}

function requireNullableString(value: unknown, path: string): string | null {
  if (value == null) return null;
  return requireString(value, path);
}

function requireNullableNumber(value: unknown, path: string): number | null {
  if (value == null) return null;
  if (typeof value !== "number" || Number.isNaN(value)) {
    throw new Error(`${path} must be a number or null`);
  }
  return value;
}

function requireBoolean(value: unknown, path: string): boolean {
  if (typeof value !== "boolean") {
    throw new Error(`${path} must be a boolean`);
  }
  return value;
}

function parseGroundTruth(value: unknown, path: string) {
  if (!isRecord(value)) throw new Error(`${path} must be an object`);
  return {
    intent: requireString(value.intent, `${path}.intent`),
    customer: requireNullableString(value.customer, `${path}.customer`),
    branch: requireNullableString(value.branch, `${path}.branch`),
    sku: requireNullableString(value.sku, `${path}.sku`),
    quantity: requireNullableNumber(value.quantity, `${path}.quantity`),
    uom: requireNullableString(value.uom, `${path}.uom`),
    confirmed_so: requireBoolean(value.confirmed_so, `${path}.confirmed_so`),
  };
}

function parseInput(value: unknown, path: string) {
  if (!isRecord(value)) throw new Error(`${path} must be an object`);
  return {
    submitter_phone: requireString(
      value.submitter_phone,
      `${path}.submitter_phone`,
    ),
    submitter_name: requireString(
      value.submitter_name,
      `${path}.submitter_name`,
    ),
    provider_message_id: requireString(
      value.provider_message_id,
      `${path}.provider_message_id`,
    ),
    message_body: requireString(value.message_body, `${path}.message_body`),
    message_type: typeof value.message_type === "string"
      ? value.message_type
      : "text",
    interpretation: isRecord(value.interpretation)
      ? value.interpretation
      : (() => {
        throw new Error(`${path}.interpretation must be an object`);
      })(),
  };
}

export function parseGoldenCase(value: unknown, index: number): GoldenCase {
  const path = `cases[${index}]`;
  if (!isRecord(value)) throw new Error(`${path} must be an object`);
  if ("core_outcome" in value || "auto_actioned" in value) {
    throw new Error(
      `${path} must not contain observed runtime fields core_outcome/auto_actioned`,
    );
  }
  return {
    id: requireString(value.id, `${path}.id`),
    traffic_class: requireString(value.traffic_class, `${path}.traffic_class`),
    input: parseInput(value.input, `${path}.input`),
    ground_truth: parseGroundTruth(value.ground_truth, `${path}.ground_truth`),
    expected_core_outcome: requireString(
      value.expected_core_outcome,
      `${path}.expected_core_outcome`,
    ),
    should_auto_action: requireBoolean(
      value.should_auto_action,
      `${path}.should_auto_action`,
    ),
    replay_twice: value.replay_twice === true,
  };
}

export function parseGoldenCorpus(value: unknown): {
  corpus: string;
  cases: GoldenCase[];
} {
  if (!isRecord(value)) throw new Error("corpus root must be an object");
  const cases = value.cases;
  if (!Array.isArray(cases) || cases.length === 0) {
    throw new Error("corpus must contain a non-empty cases array");
  }
  const parsed = cases.map((entry, index) => parseGoldenCase(entry, index));
  const ids = new Set<string>();
  for (const testCase of parsed) {
    if (ids.has(testCase.id)) {
      throw new Error(`duplicate case id: ${testCase.id}`);
    }
    ids.add(testCase.id);
  }
  return {
    corpus: requireString(value.corpus, "corpus"),
    cases: parsed,
  };
}
