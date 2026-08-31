/**
 * Stage 2 — WhatsApp historical export sanitizer.
 *
 * Accepts standard WhatsApp exported chat text (_chat.txt) or an existing
 * sanitized JSON corpus. Never logs raw message bodies.
 *
 * Usage:
 *   deno run --allow-read --allow-write --allow-env \
 *     scripts/whatsapp-stage2-historical/sanitize.ts [--dry-run] [--output PATH] INPUT
 *
 * Env:
 *   WA_PROTECTED_CORPUS_PATH — default INPUT when argv omitted
 */
import { parseGoldenCorpus } from "../whatsapp-autonomy-eval/fixture_schema.ts";
import type { GoldenCase } from "../whatsapp-autonomy-eval/types.ts";

const SANITIZATION_VERSION = "wa-stage2-sanitized-corpus/v1";
const DEFAULT_TRAFFIC_CLASS = "historical_business_message";
const PHONE_RE =
  /(?:\+?\d{1,3}[\s-]?)?(?:\(?\d{2,4}\)?[\s-]?)?\d{5}[\s-]?\d{5,6}\b/g;
const EMAIL_RE = /[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}/gi;
const UTR_RE = /\b(?:UTR|UPI|IMPS|NEFT|RTGS|REF)[:\s#-]*[A-Z0-9]{6,}\b/gi;
const ACCOUNT_RE = /\b(?:A\/C|ACCOUNT|ACC)[:\s#-]*\d{6,}\b/gi;

type ParsedMessage = {
  index: number;
  timestamp: string;
  sender_raw: string;
  body_raw: string;
  is_forwarded: boolean;
  media_type: string | null;
  is_system: boolean;
};

type CategoryCandidate = {
  traffic_class: string;
  expected_core_outcome: string;
  intent: string;
};

type SanitizeStats = {
  dry_run: boolean;
  chat_count: number;
  message_count: number;
  sanitized_case_count: number;
  category_candidates: Record<string, number>;
  rejected_records: Array<{ index: number; reason: string }>;
  schema_valid: boolean;
  corpus_hash: string;
  sanitization_method_version: string;
};

type CliOptions = {
  dryRun: boolean;
  outputPath: string | null;
  inputPath: string;
};

function usage(): never {
  console.error(
    "Usage: sanitize.ts [--dry-run] [--output PATH] [INPUT]\n" +
      "  INPUT — WhatsApp _chat.txt export or sanitized JSON corpus\n" +
      "  WA_PROTECTED_CORPUS_PATH — default INPUT when omitted",
  );
  Deno.exit(2);
}

function parseArgs(argv: string[]): CliOptions {
  let dryRun = false;
  let outputPath: string | null = null;
  const positional: string[] = [];

  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--dry-run") dryRun = true;
    else if (arg === "--output") outputPath = argv[++i] ?? usage();
    else if (arg === "--help" || arg === "-h") usage();
    else positional.push(arg);
  }

  const inputPath = positional[0] ??
    Deno.env.get("WA_PROTECTED_CORPUS_PATH") ??
    usage();

  return { dryRun, outputPath, inputPath };
}

async function sha256Hex(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

async function stablePseudonym(
  prefix: string,
  seed: string,
): Promise<string> {
  const digest = await sha256Hex(`${prefix}:${seed}`);
  if (prefix === "SENDER") {
    const digits = digest.replace(/\D/g, "").slice(0, 10).padEnd(10, "0");
    return `91${digits}`;
  }
  return `${prefix}_${digest.slice(0, 8).toUpperCase()}`;
}

function stripPii(text: string): string {
  return text
    .replace(PHONE_RE, "[PHONE_REDACTED]")
    .replace(EMAIL_RE, "[EMAIL_REDACTED]")
    .replace(UTR_RE, "[PAYMENT_REF_REDACTED]")
    .replace(ACCOUNT_RE, "[ACCOUNT_REDACTED]")
    .replace(/\b\d{12,18}\b/g, "[LONG_NUMERIC_REDACTED]");
}

function detectMediaType(body: string): string | null {
  const lower = body.toLowerCase();
  if (/<attached:|file attached|\.jpg|\.jpeg|\.png|\.webp/.test(lower)) {
    return "image";
  }
  if (/image omitted|photo omitted|sticker omitted/.test(lower)) return "image";
  if (/video omitted|\.mp4/.test(lower)) return "video";
  if (/audio omitted|\.mp3|\.opus|\.ogg/.test(lower)) return "audio";
  if (/document omitted|\.pdf|\.doc/.test(lower)) return "document";
  return null;
}

function isSystemMessage(body: string): boolean {
  const lower = body.toLowerCase();
  return (
    lower.includes("messages and calls are end-to-end encrypted") ||
    lower.includes("created group") ||
    lower.includes("changed the subject") ||
    lower.includes("changed this group's icon") ||
    lower.includes("you were added") ||
    lower.includes("security code changed")
  );
}

const MESSAGE_HEADER_RE =
  /^\[(\d{1,2}\/\d{1,2}\/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APMapm]{2})?)\]\s([^:]+):\s([\s\S]*)$/;

const SYSTEM_LINE_RE =
  /^\[(\d{1,2}\/\d{1,2}\/\d{2,4}),?\s+(\d{1,2}:\d{2}(?::\d{2})?(?:\s*[APMapm]{2})?)\]\s(.+)$/;

const GENERATED_SANITIZED_BASENAME = "stage2-sanitized.json";

function parseWhatsAppExport(text: string): ParsedMessage[] {
  const lines = text.replace(/\u200e/g, "").split(/\r?\n/);
  const messages: ParsedMessage[] = [];
  let current: ParsedMessage | null = null;
  let index = 0;

  for (const line of lines) {
    const match = line.match(MESSAGE_HEADER_RE);
    if (match) {
      if (current) messages.push(current);
      index += 1;
      const body = match[4].trim();
      current = {
        index,
        timestamp: `${match[1]} ${match[2]}`,
        sender_raw: match[3].trim(),
        body_raw: body,
        is_forwarded: /^forwarded message/i.test(body),
        media_type: detectMediaType(body),
        is_system: isSystemMessage(body),
      };
      continue;
    }

    const systemMatch = line.match(SYSTEM_LINE_RE);
    if (systemMatch && !match) {
      if (current) messages.push(current);
      index += 1;
      const remainder = systemMatch[3].trim();
      if (isSystemMessage(remainder)) {
        current = {
          index,
          timestamp: `${systemMatch[1]} ${systemMatch[2]}`,
          sender_raw: "System",
          body_raw: remainder,
          is_forwarded: false,
          media_type: detectMediaType(remainder),
          is_system: true,
        };
        continue;
      }
    }

    if (current && line.trim()) {
      current.body_raw = `${current.body_raw}\n${line}`.trim();
      current.media_type = current.media_type ??
        detectMediaType(current.body_raw);
      current.is_forwarded = current.is_forwarded ||
        /^forwarded message/i.test(current.body_raw);
      if (!current.is_system) {
        current.is_system = isSystemMessage(current.body_raw);
      }
    }
  }
  if (current) messages.push(current);
  return messages;
}

function classifyMessage(message: ParsedMessage): CategoryCandidate {
  const body = message.body_raw.toLowerCase();
  if (message.is_system) {
    return {
      traffic_class: "system",
      expected_core_outcome: "HUMAN_EXCEPTION_REQUIRED",
      intent: "SYSTEM",
    };
  }
  if (
    /(utr|upi|payment received|paid|screenshot|neft|imps|rtgs)/.test(body) ||
    message.media_type === "image" && /pay|rs\.?|inr|amount/.test(body)
  ) {
    return {
      traffic_class: "payment_proof",
      expected_core_outcome: "POLICY_APPROVAL_REQUIRED",
      intent: "PAYMENT_PROOF",
    };
  }
  if (/(correction|actually|wrong qty|revise|amend|update order)/.test(body)) {
    return {
      traffic_class: "order_correction",
      expected_core_outcome: "CLARIFICATION_REQUIRED",
      intent: "ORDER_CORRECTION",
    };
  }
  if (/(forwarded message)/.test(body) && message.is_forwarded) {
    return {
      traffic_class: "forwarded_business_message",
      expected_core_outcome: "CLARIFICATION_REQUIRED",
      intent: "FORWARDED",
    };
  }
  if (
    /(box|boxes|carton|kg|order|send|dispatch|delivery|moq|sku|bak-|cas-)/.test(
      body,
    )
  ) {
    return {
      traffic_class: "employee_mediated_order",
      expected_core_outcome: "CLARIFICATION_REQUIRED",
      intent: "NEW_ORDER",
    };
  }
  if (/(complaint|issue|damage|return|shortage)/.test(body)) {
    return {
      traffic_class: "service_exception",
      expected_core_outcome: "HUMAN_EXCEPTION_REQUIRED",
      intent: "SERVICE",
    };
  }
  return {
    traffic_class: DEFAULT_TRAFFIC_CLASS,
    expected_core_outcome: "HUMAN_EXCEPTION_REQUIRED",
    intent: "GENERAL",
  };
}

async function buildCases(
  messages: ParsedMessage[],
  corpusSeed: string,
): Promise<{
  cases: GoldenCase[];
  rejected: Array<{ index: number; reason: string }>;
  categories: Record<string, number>;
}> {
  const senderMap = new Map<string, Promise<string>>();
  const cases: GoldenCase[] = [];
  const rejected: Array<{ index: number; reason: string }> = [];
  const categories: Record<string, number> = {};

  for (const message of messages) {
    if (message.is_system) {
      rejected.push({ index: message.index, reason: "system_message" });
      continue;
    }
    const sanitizedBody = stripPii(message.body_raw).trim();
    if (!sanitizedBody) {
      rejected.push({
        index: message.index,
        reason: "empty_after_sanitization",
      });
      continue;
    }
    if (
      sanitizedBody.includes("[PHONE_REDACTED]") && sanitizedBody.length < 24
    ) {
      rejected.push({ index: message.index, reason: "phone_only_payload" });
      continue;
    }

    const category = classifyMessage(message);
    categories[category.traffic_class] =
      (categories[category.traffic_class] ?? 0) + 1;

    if (!senderMap.has(message.sender_raw)) {
      senderMap.set(
        message.sender_raw,
        stablePseudonym("SENDER", `${corpusSeed}:${message.sender_raw}`),
      );
    }
    const submitterPhone = await senderMap.get(message.sender_raw)!;
    const senderName = await stablePseudonym(
      "PARTICIPANT",
      `${corpusSeed}:${message.sender_raw}`,
    );
    const caseId = `hist-${message.index}-${
      (await sha256Hex(`${corpusSeed}:${message.index}`)).slice(0, 8)
    }`;

    const messageType = message.media_type ?? "text";
    const interpretationSummary = sanitizedBody.length > 240
      ? `${sanitizedBody.slice(0, 240)}…`
      : sanitizedBody;

    cases.push({
      id: caseId,
      traffic_class: category.traffic_class,
      input: {
        submitter_phone: submitterPhone,
        submitter_name: senderName,
        provider_message_id: `stage2-${caseId}`,
        message_body: sanitizedBody,
        message_type: messageType,
        interpretation: {
          confidence: 0,
          conclusion: {
            intent: category.intent === "NEW_ORDER" ? "ORDER" : "UNCLEAR",
            summary: interpretationSummary,
            forwarded: message.is_forwarded,
            media_type: message.media_type,
            source_timestamp: message.timestamp,
          },
        },
      },
      ground_truth: {
        intent: category.intent,
        customer: null,
        branch: null,
        sku: null,
        quantity: null,
        uom: null,
        confirmed_so: false,
      },
      expected_core_outcome: category.expected_core_outcome,
      should_auto_action: false,
      replay_twice: /correction|revise|amend/.test(sanitizedBody.toLowerCase()),
    });
  }

  return { cases, rejected, categories };
}

async function resolveInputPaths(inputPath: string): Promise<string[]> {
  const stat = await Deno.stat(inputPath);
  if (stat.isFile) return [inputPath];
  if (!stat.isDirectory) {
    throw new Error(`Input is not a file or directory: ${inputPath}`);
  }

  const paths: string[] = [];
  for await (const entry of Deno.readDir(inputPath)) {
    if (!entry.isFile) continue;
    const lower = entry.name.toLowerCase();
    if (lower === GENERATED_SANITIZED_BASENAME) continue;
    if (lower.endsWith(".sanitized.json")) continue;
    if (lower.endsWith(".txt") || lower.endsWith(".json")) {
      paths.push(`${inputPath.replace(/\/$/, "")}/${entry.name}`);
    }
  }
  paths.sort();
  if (!paths.length) {
    throw new Error(`No .txt or .json exports found under ${inputPath}`);
  }
  return paths;
}

async function resolveOutputPath(
  inputPath: string,
  options: CliOptions,
  inputPaths: string[],
): Promise<string> {
  const explicit = options.outputPath ??
    Deno.env.get("WA_STAGE2_SANITIZED_OUTPUT") ?? null;
  if (explicit) {
    const resolved = await Deno.realPath(explicit).catch(() => explicit);
    for (const src of inputPaths) {
      const srcResolved = await Deno.realPath(src).catch(() => src);
      if (resolved === srcResolved) {
        throw new Error("Output path must not equal input path");
      }
    }
    return explicit;
  }

  const inputStat = await Deno.stat(inputPath);
  if (inputStat.isDirectory) {
    return `${inputPath.replace(/\/$/, "")}/${GENERATED_SANITIZED_BASENAME}`;
  }
  if (inputPath.toLowerCase().endsWith(".json")) {
    throw new Error(
      "Refusing to overwrite sanitized JSON input; pass --output explicitly",
    );
  }
  return inputPath.replace(/\.txt$/i, ".sanitized.json");
}

async function loadExportText(path: string): Promise<string> {
  const lower = path.toLowerCase();
  if (lower.endsWith(".json")) {
    const parsed = JSON.parse(await Deno.readTextFile(path));
    if (parsed?.cases) {
      throw new Error(
        "Input is already sanitized JSON; re-sanitization is not required",
      );
    }
  }
  return await Deno.readTextFile(path);
}

async function sanitizeExports(
  inputPath: string,
  options: CliOptions,
): Promise<SanitizeStats> {
  const paths = await resolveInputPaths(inputPath);
  const parsedMessages: ParsedMessage[] = [];

  for (const path of paths) {
    const text = await loadExportText(path);
    parsedMessages.push(...parseWhatsAppExport(text));
  }

  const corpusSeed = await sha256Hex(paths.join("|"));
  const { cases, rejected, categories } = await buildCases(
    parsedMessages,
    corpusSeed,
  );

  const corpus = {
    corpus: `historical-${corpusSeed.slice(0, 12)}`,
    sanitization_method_version: SANITIZATION_VERSION,
    source_chat_count: paths.length,
    note:
      "Pseudonymized historical export. No raw phones, payment refs, or credentials.",
    cases,
  };

  const serialized = `${JSON.stringify(corpus, null, 2)}\n`;
  const corpusHash = await sha256Hex(serialized);

  let schemaValid = false;
  try {
    parseGoldenCorpus(corpus);
    schemaValid = true;
  } catch {
    schemaValid = false;
  }

  const stats: SanitizeStats = {
    dry_run: options.dryRun,
    chat_count: paths.length,
    message_count: parsedMessages.length,
    sanitized_case_count: cases.length,
    category_candidates: categories,
    rejected_records: rejected,
    schema_valid: schemaValid,
    corpus_hash: corpusHash,
    sanitization_method_version: SANITIZATION_VERSION,
  };

  if (!options.dryRun) {
    const outputPath = await resolveOutputPath(inputPath, options, paths);
    if (!schemaValid) {
      throw new Error("Sanitized corpus failed Stage 2 schema validation");
    }
    await Deno.writeTextFile(outputPath, serialized);
  }

  return stats;
}

if (import.meta.main) {
  const options = parseArgs(Deno.args);
  try {
    const stats = await sanitizeExports(options.inputPath, options);
    console.log(JSON.stringify(stats, null, 2));
    if (!stats.schema_valid) Deno.exit(1);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(JSON.stringify({ error: message }));
    Deno.exit(1);
  }
}
