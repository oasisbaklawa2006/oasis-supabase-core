/** @file Trusted WhatsApp packet AI worker with governed B2B case orchestration. */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import {
  downloadGovernedWhatsAppMedia,
  parseGovernedWhatsAppMediaUrl,
  readBoundedResponseBody,
} from "../_shared/whatsappGovernedMediaFetch.ts";
import { sanitizeInterpretResult } from "../whatsapp-content-interpret/sanitize.ts";
import {
  buildGeminiRequest,
  callGeminiGenerateContent,
  GEMINI_MODEL,
  type GeminiPart,
  inlineMediaPart,
  textPart,
} from "../_shared/geminiProvider.ts";

export {
  parseGovernedWhatsAppMediaUrl as allowedMediaUrl,
  readBoundedResponseBody as readBoundedBody,
};

const JSON_HEADERS = { "Content-Type": "application/json" };
const MAX_PACKET_MESSAGES = 16;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_MEDIA_BYTES = 15 * 1024 * 1024;
const MAX_PACKET_MEDIA_BYTES = 24 * 1024 * 1024;
const MODEL = GEMINI_MODEL;
const PROVIDER = "google-gemini";
const INTERPRETATION_SCHEMA_VERSION = "wa-packet-interpretation/v1";
const PROMPT_POLICY_VERSION = "wa-packet-policy/v3";
const RESOLVER_POLICY_VERSION = "wa-resolver-policy/v1";
const MEDIA_TYPES = new Set(["image", "audio", "video", "document"]);
const ALLOWED_INTENTS = new Set([
  "NEW_ORDER",
  "AMENDMENT",
  "CANCELLATION",
  "ENQUIRY",
  "COMPLAINT",
  "PAYMENT_ADVICE",
  "ACCOUNT_QUERY",
  "DELIVERY_QUERY",
  "SPECIFICATION_QUERY",
  "OTHER",
  "UNCLEAR",
]);
const ALLOWED_DEPARTMENTS = new Set([
  "SALES",
  "FINANCE",
  "QUALITY",
  "DISPATCH",
  "LOGISTICS",
  "PRODUCTION",
  "PACKAGING",
  "OPERATIONS",
  "CUSTOMER_SERVICE",
]);
const ALLOWED_REPLY_CLEARANCE = new Set([
  "EMPLOYEE_REVIEW_REQUIRED",
  "SUBJECT_EXPERT_REVIEW_REQUIRED",
  "MANAGEMENT_APPROVAL_REQUIRED",
  "BLOCKED_INACCURATE_OR_UNSUPPORTED",
  "CLARIFICATION_REQUIRED",
  "SAFE_TO_SEND_AUTOMATICALLY",
]);
const DEFAULT_REPLY_CLEARANCE = "EMPLOYEE_REVIEW_REQUIRED";

const IMAGE_MIME = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
]);
const AUDIO_MIME = new Set([
  "audio/mpeg",
  "audio/mp3",
  "audio/mp4",
  "audio/x-m4a",
  "audio/ogg",
  "audio/wav",
  "audio/x-wav",
  "audio/webm",
]);
const VIDEO_MIME = new Set(["video/mp4", "video/webm", "video/quicktime"]);
const DOCUMENT_MIME = new Set(["application/pdf"]);
const MIME_ALLOWLIST_BY_TYPE = new Map<string, Set<string>>([
  ["image", IMAGE_MIME],
  ["audio", AUDIO_MIME],
  ["video", VIDEO_MIME],
  ["document", DOCUMENT_MIME],
]);

type PacketMessage = {
  provider_message_id: string | null;
  content: string | null;
  message_type: string | null;
  media_url: string | null;
  message_timestamp: string | null;
  packet_sequence: number | null;
};

export type LoadedMessage = {
  providerMessageId: string;
  content: string;
  messageType: string;
  mediaUrl: string;
  timestamp: string;
};

type DispatchLease = {
  id: string;
  packet_id: string;
  packet_revision: number;
  lease_token: string;
  execution_kind: "PACKET" | "CASE_CONTEXT";
  case_id: string | null;
  context_revision: number | null;
};

const respond = (body: Record<string, unknown>, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: JSON_HEADERS });

const safeString = (value: unknown, max: number): string =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

const safeStringArray = (
  value: unknown,
  maxItems: number,
  maxLength: number,
): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim().slice(0, maxLength))
    .filter(Boolean)
    .slice(0, maxItems);
};

const systemPrompt =
  `You are the B2B WhatsApp evidence interpreter and decision-support engine for Oasis Baklawa.
Understand the ENTIRE chronological evidence packet before a human decides. Evidence can be clean or badly typed English, Hindi/Devanagari, Roman Hinglish, phonetic spellings, abbreviations, misspellings, photographs, screenshots, handwriting, voice notes, videos, and PDF purchase orders.

Rules:
1. Preserve provenance. Cite provider_message_id for explicit facts and corrections.
2. Understand obvious spelling/transliteration variants, but never invent product, SKU, quantity, unit, price, customer, payment, stock, credit, delivery date, availability or promises.
3. Later explicit corrections supersede earlier conflicting instructions and must be recorded, not silently erased.
4. Read only visible/audible/documented facts. Illegible or unavailable evidence becomes an ambiguity.
5. Distinguish explicit facts from interpreted normalization.
6. Reach a concise B2B conclusion and recommended next HUMAN action. AI creates no commitment.
7. normalized_text must remain useful to downstream catalogue/quantity resolution and contain explicit quantities/corrections only.
8. Classify the business case, not merely whether it resembles an order. Use the narrowest supported intent.
9. Recommend one accountable response department and any contributor departments. This is advisory: never claim a person accepted ownership.
10. Draft a concise customer reply only from supported evidence. Never claim payment verified, stock available, credit approved, production complete, dispatch committed, or a delivery promise unless explicit authoritative evidence is in this packet. Automatic customer sends are decided only by deterministic Core policy after materialization, never by AI reply_clearance alone.
11. reply_clearance and draft_reply are advisory only. They do not grant automatic send authority. Core decides AUTO_SAFE_ACK, AUTO_CLARIFICATION, or HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED from governed outcomes.
12. For mixed-intent packets, choose the primary intent and list contributor departments needed for one consolidated customer response.

Allowed primary/contributor department labels:
SALES, FINANCE, QUALITY, DISPATCH, LOGISTICS, PRODUCTION, PACKAGING, OPERATIONS, CUSTOMER_SERVICE.

Return JSON only:
{
  "normalized_text":"...",
  "extracted_text":"...",
  "language":"...",
  "confidence":0.0,
  "warnings":[],
  "source_kind":"packet",
  "conclusion":{
    "intent":"NEW_ORDER|AMENDMENT|CANCELLATION|ENQUIRY|COMPLAINT|PAYMENT_ADVICE|ACCOUNT_QUERY|DELIVERY_QUERY|SPECIFICATION_QUERY|OTHER|UNCLEAR",
    "summary":"...",
    "explicit_facts":[{"provider_message_id":"...","kind":"...","value":"..."}],
    "order_lines":[{"product_name":"...","sku":"","quantity":null,"unit":"","status":"explicit|interpreted|unclear","evidence_ids":["..."]}],
    "corrections":[{"provider_message_id":"...","supersedes":"...","replacement":"..."}],
    "ambiguities":[],
    "primary_department":"SALES|FINANCE|QUALITY|DISPATCH|LOGISTICS|PRODUCTION|PACKAGING|OPERATIONS|CUSTOMER_SERVICE|",
    "contributor_departments":[],
    "reply_clearance":"EMPLOYEE_REVIEW_REQUIRED|SUBJECT_EXPERT_REVIEW_REQUIRED|MANAGEMENT_APPROVAL_REQUIRED|BLOCKED_INACCURATE_OR_UNSUPPORTED|CLARIFICATION_REQUIRED|SAFE_TO_SEND_AUTOMATICALLY",
    "draft_reply":"...",
    "recommended_action":"...",
    "human_review_required":true,
    "automatic_action_authority":"HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED"
  }
}`;

// skipcq: JS-R1005
export const validateMime = (type: string, mime: string): void => {
  const allowed = MIME_ALLOWLIST_BY_TYPE.get(type);
  if (!allowed) return;
  if (!allowed.has(mime)) {
    throw new Error(`UNSUPPORTED_${type.toUpperCase()}_TYPE`);
  }
};

function maxBytes(type: string): number {
  return type === "image" ? MAX_IMAGE_BYTES : MAX_MEDIA_BYTES;
}

export const handleAsync = <T>(
  maybePromise: PromiseLike<T>,
): Promise<[T, undefined] | [undefined, Error]> =>
  Promise.resolve(maybePromise)
    .then((data): [T, undefined] => [data, undefined])
    .catch((error): [undefined, Error] => [
      undefined,
      error instanceof Error ? error : new Error("ASYNC_TRANSPORT_FAILED"),
    ]);

type PostgrestRpcResponse<T> = {
  data: T;
  error: { message: string } | null;
};

function withDispatchLeaseRpcArgs(
  base: Record<string, unknown>,
  lease?: DispatchLease | null,
): Record<string, unknown> {
  if (!lease) return base;
  return {
    ...base,
    p_job_id: lease.id,
    p_lease_token: lease.lease_token,
    p_packet_revision: lease.packet_revision,
  };
}

async function rpcWithTransport<T>(
  failureCode: string,
  maybePromise: PromiseLike<PostgrestRpcResponse<T>>,
): Promise<T> {
  try {
    const [response, transportErr] = await handleAsync(maybePromise);
    if (transportErr) {
      throw new Error(
        `${failureCode}:${safeString(transportErr.message, 120)}`,
      );
    }
    if (response.error) {
      throw new Error(
        `${failureCode}:${safeString(response.error.message, 120)}`,
      );
    }
    return response.data;
  } catch (error) {
    throw error instanceof Error
      ? error
      : new Error(`${failureCode}:ASYNC_TRANSPORT_FAILED`);
  }
}

export type KnowledgeSnapshot = {
  id: string;
  schema_version: string;
  content_checksum: string;
  knowledge: Record<string, unknown>;
};

const MAX_KNOWLEDGE_CONTEXT_CHARS = 12000;

export function formatKnowledgeSnapshotContext(
  snapshot: KnowledgeSnapshot,
): string {
  const knowledgeJson = JSON.stringify(snapshot.knowledge);
  if (knowledgeJson.length > MAX_KNOWLEDGE_CONTEXT_CHARS) {
    throw new Error("KNOWLEDGE_SNAPSHOT_CONTEXT_TOO_LARGE");
  }
  return [
    "Governed intelligence knowledge snapshot",
    `schema_version=${snapshot.schema_version}`,
    `content_checksum=${snapshot.content_checksum}`,
    `knowledge=${knowledgeJson}`,
  ].join("\n");
}

function evidenceLabel(message: LoadedMessage, extra = ""): string {
  return `[evidence provider_message_id=${message.providerMessageId} type=${message.messageType}${
    message.timestamp ? ` time=${message.timestamp}` : ""
  }${extra}]`;
}

async function prepareContent(
  messages: LoadedMessage[],
  knowledgeSnapshot: KnowledgeSnapshot,
): Promise<{
  parts: GeminiPart[];
  warnings: string[];
  processedMediaIds: string[];
}> {
  const knowledgeContext = formatKnowledgeSnapshotContext(knowledgeSnapshot);
  const parts: GeminiPart[] = [
    textPart(`${systemPrompt}\n\n${knowledgeContext}`),
  ];
  const warnings: string[] = [];
  const processedMediaIds: string[] = [];
  let packetBytes = 0;

  for (const message of messages) {
    if (!MEDIA_TYPES.has(message.messageType)) {
      parts.push(
        textPart(
          `${evidenceLabel(message)}\n${message.content || "[empty text]"}`,
        ),
      );
      continue;
    }

    if (!message.mediaUrl) {
      warnings.push(
        `${message.providerMessageId}: ${message.messageType} has no retrievable media URL`,
      );
      parts.push(
        textPart(
          `${evidenceLabel(message, " media_unavailable=true")}\n${
            message.content || "[media unavailable]"
          }`,
        ),
      );
      continue;
    }

    try {
      const media = await downloadGovernedWhatsAppMedia(
        message.mediaUrl,
        maxBytes(message.messageType),
      );
      validateMime(message.messageType, media.mime);
      packetBytes += media.bytes.byteLength;
      if (packetBytes > MAX_PACKET_MEDIA_BYTES) {
        throw new Error("PACKET_MEDIA_TOO_LARGE");
      }

      parts.push(
        textPart(
          `${evidenceLabel(message)}${
            message.content ? `\nCAPTION: ${message.content}` : ""
          }`,
        ),
      );
      parts.push(inlineMediaPart(media.bytes, media.mime));
      processedMediaIds.push(message.providerMessageId);
    } catch (error) {
      const code = error instanceof Error
        ? error.message
        : "MEDIA_PROCESSING_FAILED";
      warnings.push(`${message.providerMessageId}: ${code}`);
      parts.push(
        textPart(
          `${evidenceLabel(message, " media_processing_failed=true")}\n${
            message.content || "[media could not be interpreted]"
          }`,
        ),
      );
    }
  }

  return { parts, warnings, processedMediaIds };
}

async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

async function loadPacket(
  admin: SupabaseClient,
  packetId: string,
): Promise<LoadedMessage[]> {
  const [packetResponse, packetTransportErr] = await handleAsync(
    admin
      .from("whatsapp_message_packets")
      .select("id")
      .eq("id", packetId)
      .maybeSingle(),
  );
  if (packetTransportErr) {
    throw new Error(
      `PACKET_LOOKUP_FAILED:${safeString(packetTransportErr.message, 120)}`,
    );
  }
  const { data: packet, error: packetError } = packetResponse;
  if (packetError || !packet) throw new Error("PACKET_NOT_FOUND");

  const [messageResponse, messageTransportErr] = await handleAsync(
    admin
      .from("whatsapp_messages")
      .select(
        "provider_message_id, content, message_type, media_url, message_timestamp, packet_sequence",
      )
      .eq("packet_id", packetId)
      .eq("direction", "inbound")
      .order("packet_sequence", { ascending: true })
      .limit(MAX_PACKET_MESSAGES + 1),
  );
  if (messageTransportErr) {
    throw new Error(
      `PACKET_MESSAGE_LOOKUP_FAILED:${
        safeString(messageTransportErr.message, 120)
      }`,
    );
  }
  const { data, error } = messageResponse;
  if (error) throw new Error("PACKET_MESSAGE_LOOKUP_FAILED");
  const rows = (data ?? []) as PacketMessage[];
  if (!rows.length) throw new Error("PACKET_EMPTY");
  if (rows.length > MAX_PACKET_MESSAGES) {
    throw new Error("INTERPRETATION_PACKET_TOO_LARGE");
  }
  return rows.map((row) => ({
    providerMessageId: safeString(row.provider_message_id, 240),
    content: safeString(row.content, 6000),
    messageType: safeString(row.message_type, 40).toLowerCase() || "text",
    mediaUrl: safeString(row.media_url, 5000),
    timestamp: safeString(row.message_timestamp, 80),
  })).filter((row) => Boolean(row.providerMessageId));
}

async function loadCaseContext(
  admin: SupabaseClient,
  caseId: string,
): Promise<LoadedMessage[]> {
  const [rpcResponse, rpcTransportErr] = await handleAsync(
    admin.rpc("whatsapp_case_context_messages", {
      p_case_id: caseId,
    }),
  );
  if (rpcTransportErr) {
    throw new Error(
      `CASE_CONTEXT_MESSAGE_LOOKUP_FAILED:${
        safeString(rpcTransportErr.message, 120)
      }`,
    );
  }
  const { data, error } = rpcResponse;
  if (error) throw new Error("CASE_CONTEXT_MESSAGE_LOOKUP_FAILED");
  const rows = (data ?? []) as PacketMessage[];
  if (!rows.length) throw new Error("CASE_CONTEXT_EMPTY");
  if (rows.length > MAX_PACKET_MESSAGES) {
    throw new Error("INTERPRETATION_PACKET_TOO_LARGE");
  }
  return rows.map((row) => ({
    providerMessageId: safeString(row.provider_message_id, 240),
    content: safeString(row.content, 6000),
    messageType: safeString(row.message_type, 40).toLowerCase() || "text",
    mediaUrl: safeString(row.media_url, 5000),
    timestamp: safeString(row.message_timestamp, 80),
  })).filter((row) => Boolean(row.providerMessageId));
}

function parseActiveKnowledgeSnapshotResult(
  data: Record<string, unknown> | null,
  error: { message: string } | null,
): KnowledgeSnapshot {
  if (error) {
    throw new Error(
      `KNOWLEDGE_SNAPSHOT_LOAD_FAILED:${safeString(error.message, 120)}`,
    );
  }
  if (!data || typeof data !== "object") {
    throw new Error("KNOWLEDGE_SNAPSHOT_NOT_ACTIVELY_GOVERNED");
  }
  const id = safeString(data.id, 80);
  const schemaVersion = safeString(data.schema_version, 120);
  const contentChecksum = safeString(data.content_checksum, 80);
  const knowledge = data.knowledge;
  if (
    !id || !schemaVersion || contentChecksum.length !== 64 ||
    !knowledge || typeof knowledge !== "object" || Array.isArray(knowledge)
  ) {
    throw new Error("KNOWLEDGE_SNAPSHOT_MALFORMED");
  }
  return {
    id,
    schema_version: schemaVersion,
    content_checksum: contentChecksum,
    knowledge: knowledge as Record<string, unknown>,
  };
}

async function loadActiveKnowledgeSnapshot(
  admin: SupabaseClient,
): Promise<KnowledgeSnapshot> {
  const [snapshotResponse, snapshotTransportErr] = await handleAsync(
    admin.rpc("whatsapp_active_intelligence_knowledge_snapshot"),
  );
  if (snapshotTransportErr) {
    throw new Error(
      `KNOWLEDGE_SNAPSHOT_LOAD_FAILED:${
        safeString(snapshotTransportErr.message, 120)
      }`,
    );
  }
  return parseActiveKnowledgeSnapshotResult(
    snapshotResponse.data as Record<string, unknown> | null,
    snapshotResponse.error,
  );
}

// skipcq: JS-R1005
export const sanitizeInterpretation = (
  raw: unknown,
  messages: LoadedMessage[],
  infrastructureWarnings: string[],
): Record<string, unknown> => {
  if (!raw || typeof raw !== "object" || Array.isArray(raw)) {
    throw new Error("INTERPRETER_INVALID_SCHEMA");
  }
  const obj = raw as Record<string, unknown>;
  if (
    !obj.conclusion || typeof obj.conclusion !== "object" ||
    Array.isArray(obj.conclusion)
  ) {
    throw new Error("INTERPRETER_INVALID_SCHEMA");
  }

  const conclusionRaw = obj.conclusion as Record<string, unknown>;
  const intent = safeString(conclusionRaw.intent, 32).toUpperCase();
  if (!ALLOWED_INTENTS.has(intent)) {
    throw new Error("INTERPRETER_INVALID_SCHEMA");
  }

  const allowedIds = new Set(
    messages.map((message) => message.providerMessageId),
  );
  const base = sanitizeInterpretResult(
    raw,
    "packet",
    infrastructureWarnings,
    allowedIds,
  );
  if (!base.conclusion.summary || !base.conclusion.recommended_action) {
    throw new Error("INTERPRETER_INVALID_SCHEMA");
  }

  const primaryDepartmentRaw = safeString(conclusionRaw.primary_department, 32)
    .toUpperCase();
  const primaryDepartment = ALLOWED_DEPARTMENTS.has(primaryDepartmentRaw)
    ? primaryDepartmentRaw
    : "";

  const contributorDepartments = safeStringArray(
    conclusionRaw.contributor_departments,
    8,
    32,
  )
    .map((value) => value.toUpperCase())
    .filter((value) => ALLOWED_DEPARTMENTS.has(value));

  const replyClearanceRaw = safeString(conclusionRaw.reply_clearance, 40)
    .toUpperCase();
  const replyClearance = ALLOWED_REPLY_CLEARANCE.has(replyClearanceRaw)
    ? replyClearanceRaw
    : DEFAULT_REPLY_CLEARANCE;

  return {
    ...base,
    conclusion: {
      ...base.conclusion,
      intent,
      primary_department: primaryDepartment,
      contributor_departments: contributorDepartments,
      reply_clearance: replyClearance,
      draft_reply: safeString(conclusionRaw.draft_reply, 4000),
      human_review_required: true,
      automatic_action_authority: "HUMAN_OR_DEPARTMENT_REVIEW_REQUIRED",
    },
  };
};

async function callAi(
  apiKey: string,
  messages: LoadedMessage[],
  knowledgeSnapshot: KnowledgeSnapshot,
) {
  const prepared = await prepareContent(messages, knowledgeSnapshot);
  const raw = await callGeminiGenerateContent(
    apiKey,
    buildGeminiRequest(prepared.parts),
  );
  let parsed: unknown;
  try {
    parsed = JSON.parse(raw);
  } catch {
    throw new Error("INTERPRETER_INVALID_JSON");
  }
  return {
    interpretation: sanitizeInterpretation(parsed, messages, prepared.warnings),
    processedMediaIds: prepared.processedMediaIds,
  };
}

async function completeOneMedia(
  admin: SupabaseClient,
  providerId: string,
  fingerprint: string,
): Promise<void> {
  try {
    await rpcWithTransport(
      `MEDIA_COMPLETION_FAILED:${providerId}`,
      admin.rpc("complete_whatsapp_media_processing", {
        p_provider_message_id: providerId,
        p_state: "SUCCEEDED",
        p_attempt_key: `packet-ai:${fingerprint}`,
        p_detail: {
          worker: "whatsapp-packet-ai-worker",
          provider: PROVIDER,
          model: MODEL,
        },
      }),
    );
  } catch (error) {
    throw error instanceof Error ? error : new Error(
      `MEDIA_COMPLETION_FAILED:${providerId}:ASYNC_TRANSPORT_FAILED`,
    );
  }
}

export async function completeMediaSequentially(
  admin: SupabaseClient,
  ids: string[],
  fingerprint: string,
): Promise<void> {
  try {
    const uniqueIds = [...new Set(ids)];
    for (const providerId of uniqueIds) {
      await completeOneMedia(admin, providerId, fingerprint);
    }
  } catch (error) {
    throw error instanceof Error
      ? error
      : new Error("MEDIA_COMPLETION_FAILED:ASYNC_TRANSPORT_FAILED");
  }
}

async function materializeCase(
  admin: SupabaseClient,
  packetId: string,
  interpretationId: string,
  lease?: DispatchLease | null,
): Promise<Record<string, unknown>> {
  const data = await rpcWithTransport(
    "CASE_MATERIALIZATION_FAILED",
    admin.rpc(
      "whatsapp_materialize_packet_ai_case",
      withDispatchLeaseRpcArgs({
        p_packet_id: packetId,
        p_interpretation_id: interpretationId,
      }, lease),
    ),
  );
  return data && typeof data === "object"
    ? data as Record<string, unknown>
    : {};
}

async function persistInterpretationGoverned(
  admin: SupabaseClient,
  packetId: string,
  fingerprint: string,
  providerIds: string[],
  interpretation: Record<string, unknown>,
  knowledgeSnapshot: KnowledgeSnapshot,
  lease?: DispatchLease | null,
): Promise<string> {
  const data = await rpcWithTransport(
    "INTERPRETATION_PERSIST_FAILED",
    admin.rpc(
      "whatsapp_persist_packet_ai_interpretation_governed",
      withDispatchLeaseRpcArgs({
        p_packet_id: packetId,
        p_content_fingerprint: fingerprint,
        p_provider_message_ids: providerIds,
        p_interpretation: interpretation,
        p_model_version: `${PROVIDER}/${MODEL}`,
        p_knowledge_snapshot_id: knowledgeSnapshot.id,
        p_knowledge_snapshot_schema_version: knowledgeSnapshot.schema_version,
        p_knowledge_snapshot_content_checksum:
          knowledgeSnapshot.content_checksum,
        p_interpretation_schema_version: INTERPRETATION_SCHEMA_VERSION,
        p_prompt_policy_version: PROMPT_POLICY_VERSION,
        p_resolver_policy_version: RESOLVER_POLICY_VERSION,
      }, lease),
    ),
  );
  const id = safeString(data, 80);
  if (!id) throw new Error("INTERPRETATION_ID_MISSING");
  return id;
}

function parseDispatchLeaseRow(data: unknown): DispatchLease | null {
  if (!data) return null;
  const row = data as Record<string, unknown>;
  const id = safeString(row.id, 80);
  const packetId = safeString(row.packet_id, 80);
  const token = safeString(row.lease_token, 80);
  const revision = Number(row.packet_revision);
  const executionKind = safeString(row.execution_kind, 32);
  const caseId = safeString(row.case_id, 80) || null;
  const contextRevisionRaw = row.context_revision;
  const contextRevision =
    contextRevisionRaw === null || contextRevisionRaw === undefined
      ? null
      : Number(contextRevisionRaw);
  const caseContextValid = executionKind !== "CASE_CONTEXT" || (
    caseId && contextRevision !== null &&
    Number.isSafeInteger(contextRevision) && contextRevision >= 1
  );
  if (
    !id || !packetId || !token || !Number.isSafeInteger(revision) ||
    revision < 1 ||
    (executionKind !== "PACKET" && executionKind !== "CASE_CONTEXT") ||
    !caseContextValid
  ) {
    throw new Error("DISPATCH_CLAIM_INVALID");
  }
  return {
    id,
    packet_id: packetId,
    packet_revision: revision,
    lease_token: token,
    execution_kind: executionKind as "PACKET" | "CASE_CONTEXT",
    case_id: caseId,
    context_revision: contextRevision,
  };
}

async function claimDispatchLease(
  admin: SupabaseClient,
): Promise<DispatchLease | null> {
  const data = await rpcWithTransport(
    "DISPATCH_CLAIM_FAILED",
    admin.rpc("claim_whatsapp_packet_ai_dispatch_job", {
      p_lease_seconds: 120,
    }),
  );
  return parseDispatchLeaseRow(data);
}

async function completeDispatchLease(
  admin: SupabaseClient,
  lease: DispatchLease,
): Promise<void> {
  try {
    const data = await rpcWithTransport(
      "DISPATCH_COMPLETE_FAILED",
      admin.rpc("complete_whatsapp_packet_ai_dispatch_job", {
        p_job_id: lease.id,
        p_lease_token: lease.lease_token,
        p_packet_revision: lease.packet_revision,
      }),
    );
    if (data !== true) throw new Error("DISPATCH_COMPLETE_FAILED");
  } catch (error) {
    throw error instanceof Error
      ? error
      : new Error("DISPATCH_COMPLETE_FAILED");
  }
}

async function retryDispatchLease(
  admin: SupabaseClient,
  lease: DispatchLease,
  error: unknown,
): Promise<void> {
  const code = error instanceof Error
    ? error.message.split(":")[0]
    : "PACKET_AI_FAILED";
  if (code === "DISPATCH_LEASE_SUPERSEDED") return;
  const knowledge = code.startsWith("KNOWLEDGE_SNAPSHOT_");
  try {
    await rpcWithTransport(
      "DISPATCH_RETRY_FAILED",
      admin.rpc("retry_whatsapp_packet_ai_dispatch_job", {
        p_job_id: lease.id,
        p_lease_token: lease.lease_token,
        p_packet_revision: lease.packet_revision,
        p_error_code: code,
        p_error_detail: error instanceof Error
          ? error.message.slice(0, 500)
          : "",
        p_knowledge_authority_failure: knowledge,
      }),
    );
  } catch (retryDispatchError) {
    const message = retryDispatchError instanceof Error
      ? retryDispatchError.message
      : "DISPATCH_RETRY_FAILED";
    throw new Error(message);
  }
}

/**
 * Accepts only a service_role JWT after Supabase verify_jwt has already
 * validated the token signature and project scope at the Edge gateway.
 *
 * Preview runtimes may inject a modern sb_secret_* value into
 * SUPABASE_SERVICE_ROLE_KEY while trusted callers still authenticate with
 * the legacy service_role JWT, so byte-for-byte token/secret equality is
 * intentionally not used here.
 */
export const trustedServiceRoleAuthorization = (
  authorization: string,
): boolean => {
  const match = authorization.trim().match(/^Bearer\s+([^\s]+)$/i);
  if (!match) return false;

  const parts = match[1].split(".");
  if (parts.length !== 3) return false;

  try {
    const encoded = parts[1].replace(/-/g, "+").replace(/_/g, "/");
    const padded = encoded.padEnd(Math.ceil(encoded.length / 4) * 4, "=");
    const decoded = atob(padded);
    const bytes = Uint8Array.from(
      decoded,
      (character) => character.charCodeAt(0),
    );
    const payload = JSON.parse(new TextDecoder().decode(bytes));

    return Boolean(
      payload &&
        typeof payload === "object" &&
        !Array.isArray(payload) &&
        (payload as Record<string, unknown>).role === "service_role",
    );
  } catch {
    return false;
  }
};
async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authorization = req.headers.get("Authorization") ?? "";
  if (!serviceRoleKey || !trustedServiceRoleAuthorization(authorization)) {
    return respond(
      { success: false, error: "TRUSTED_PROCESSOR_REQUIRED" },
      401,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const apiKey = Deno.env.get("GEMINI_API_KEY");
  if (!supabaseUrl || !apiKey) {
    return respond({ success: false, error: "WORKER_NOT_CONFIGURED" }, 503);
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const claimNext = body.claim_next === true;
  let lease: DispatchLease | null = null;
  if (claimNext) {
    try {
      lease = await claimDispatchLease(admin);
    } catch (claimError) {
      throw claimError instanceof Error
        ? claimError
        : new Error("DISPATCH_CLAIM_FAILED");
    }
  }
  if (claimNext && !lease) return respond({ success: true, idle: true });
  const packetId = lease?.packet_id ?? safeString(body.packet_id, 80);
  if (
    !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
      .test(packetId)
  ) {
    return respond({ success: false, error: "PACKET_ID_REQUIRED" }, 400);
  }

  try {
    const messages = lease?.execution_kind === "CASE_CONTEXT" && lease.case_id
      ? await loadCaseContext(admin, lease.case_id)
      : await loadPacket(admin, packetId);
    const knowledgeSnapshot = await loadActiveKnowledgeSnapshot(admin);
    const providerIds = messages.map((message) => message.providerMessageId);
    const fingerprint = await sha256(
      messages.map((message) =>
        [
          message.providerMessageId,
          message.messageType,
          message.content,
          message.timestamp,
        ].join("|")
      ).join("\n"),
    );

    const { data: existing, error: existingError } = await admin
      .from("whatsapp_packet_ai_interpretations")
      .select("id, interpretation")
      .eq("packet_id", packetId)
      .eq("content_fingerprint", fingerprint)
      .maybeSingle();
    if (existingError) {
      throw new Error(
        `INTERPRETATION_CACHE_LOOKUP_FAILED:${
          safeString(existingError.message, 120)
        }`,
      );
    }

    if (existing?.id) {
      const retried = await prepareContent(messages, knowledgeSnapshot);
      await completeMediaSequentially(
        admin,
        retried.processedMediaIds,
        fingerprint,
      );
      const caseResult = await materializeCase(
        admin,
        packetId,
        String(existing.id),
        lease,
      );
      if (lease) await completeDispatchLease(admin, lease);
      return respond({
        success: true,
        cached: true,
        packet_id: packetId,
        content_fingerprint: fingerprint,
        interpretation: existing.interpretation,
        communication_case: caseResult,
      });
    }

    const result = await callAi(apiKey, messages, knowledgeSnapshot);
    await completeMediaSequentially(
      admin,
      result.processedMediaIds,
      fingerprint,
    );

    const interpretationId = await persistInterpretationGoverned(
      admin,
      packetId,
      fingerprint,
      providerIds,
      result.interpretation,
      knowledgeSnapshot,
      lease,
    );

    const caseResult = await materializeCase(
      admin,
      packetId,
      interpretationId,
      lease,
    );
    if (lease) await completeDispatchLease(admin, lease);
    return respond({
      success: true,
      packet_id: packetId,
      content_fingerprint: fingerprint,
      interpretation: result.interpretation,
      communication_case: caseResult,
    });
  } catch (error) {
    if (lease) {
      await retryDispatchLease(admin, lease, error).catch((retryError) => {
        console.error(
          "[whatsapp-packet-ai-worker]",
          retryError instanceof Error
            ? retryError.message.slice(0, 240)
            : "DISPATCH_RETRY_FAILED",
        );
      });
    }
    throw error;
  }
}

if (import.meta.main) {
  serve(async (req) => {
    try {
      return await handleRequest(req);
    } catch (error) {
      const code = error instanceof Error ? error.message : "PACKET_AI_FAILED";
      console.error("[whatsapp-packet-ai-worker]", code.slice(0, 240));
      return respond({ success: false, error: code.slice(0, 240) }, 502);
    }
  });
}

export { claimDispatchLease };
