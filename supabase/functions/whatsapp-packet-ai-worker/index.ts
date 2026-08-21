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

// Preserve the worker's test surface without duplicating #82's governed media
// implementation. These aliases point directly at the canonical shared helper.
export {
  parseGovernedWhatsAppMediaUrl as allowedMediaUrl,
  readBoundedResponseBody as readBoundedBody,
};

const JSON_HEADERS = { "Content-Type": "application/json" };
const MAX_PACKET_MESSAGES = 16;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_MEDIA_BYTES = 15 * 1024 * 1024;
const MAX_PACKET_MEDIA_BYTES = 24 * 1024 * 1024;
const CHAT_GATEWAY = "https://ai.gateway.lovable.dev/v1/chat/completions";
const TRANSCRIPTION_GATEWAY =
  "https://ai.gateway.lovable.dev/v1/audio/transcriptions";
const MODEL = "google/gemini-3.6-flash";
const INTERPRETATION_SCHEMA_VERSION = "wa-packet-interpretation/v1";
const PROMPT_POLICY_VERSION = "wa-packet-policy/v1";
const RESOLVER_POLICY_VERSION = "wa-resolver-policy/v1";
const TRANSCRIPTION_MODEL = "openai/gpt-4o-mini-transcribe";
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

const AUDIO_EXTENSION_HINTS: ReadonlyArray<[string, string]> = [
  ["mpeg", "mp3"],
  ["mp3", "mp3"],
  ["m4a", "m4a"],
  ["ogg", "ogg"],
  ["wav", "wav"],
  ["webm", "webm"],
];

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

type MediaPayload = { bytes: Uint8Array; mime: string };
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
Understand the ENTIRE chronological evidence packet before a human decides. Evidence can be clean or badly typed English, Hindi/Devanagari, Roman Hinglish, phonetic spellings, abbreviations, misspellings, photographs, screenshots, handwriting, voice-note transcripts, videos, and PDF purchase orders.

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
10. Draft a concise customer reply only from supported evidence. Never claim payment verified, stock available, credit approved, production complete, dispatch committed, or a delivery promise unless explicit authoritative evidence is in this packet. The draft is never sent automatically.
11. reply_clearance is advisory only and never authorizes sending. Prefer CLARIFICATION_REQUIRED when a business-critical fact is unresolved.
12. For mixed-intent packets, choose the primary intent and list contributor departments needed for one consolidated customer response.

Allowed primary/contributor department labels for advisory routing:
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
    "human_review_required":true
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

/** Returns the byte ceiling for a governed media message type. skipcq: JS-0067 */
function maxBytes(type: string): number {
  return type === "image" ? MAX_IMAGE_BYTES : MAX_MEDIA_BYTES;
}

/** Encodes governed media bytes as a data URL for multimodal gateways. skipcq: JS-0067 */
function bytesToDataUrl(bytes: Uint8Array, mime: string): string {
  let binary = "";
  const chunk = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunk) {
    binary += String.fromCharCode(
      ...bytes.subarray(offset, Math.min(offset + chunk, bytes.length)),
    );
  }
  return `data:${mime};base64,${btoa(binary)}`;
}

/** Maps audio MIME types to a stable file extension for transcription. skipcq: JS-0067, JS-R1005 */
function audioExtension(mime: string): string {
  for (const [hint, extension] of AUDIO_EXTENSION_HINTS) {
    if (mime.includes(hint)) return extension;
  }
  if (mime === "audio/mp4") return "m4a";
  return "audio";
}

/** Transcribes governed audio evidence through the Lovable gateway. skipcq: JS-0067 */
async function transcribeAudio(
  apiKey: string,
  media: MediaPayload,
): Promise<string> {
  const form = new FormData();
  form.append(
    "file",
    new Blob([new Uint8Array(media.bytes)], { type: media.mime }),
    `whatsapp-voice.${audioExtension(media.mime)}`,
  );
  form.append("model", TRANSCRIPTION_MODEL);
  const response = await fetch(TRANSCRIPTION_GATEWAY, {
    method: "POST",
    headers: { "Lovable-API-Key": apiKey },
    body: form,
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) throw new Error(`TRANSCRIPTION_${response.status}`);
  const payload = await response.json() as Record<string, unknown>;
  const transcript = safeString(payload.text, 10000);
  if (!transcript) throw new Error("AUDIO_TRANSCRIPTION_EMPTY");
  return transcript;
}

/** Builds a provenance label for one inbound evidence message. skipcq: JS-0067 */
function evidenceLabel(message: LoadedMessage, extra = ""): string {
  return `[evidence provider_message_id=${message.providerMessageId} type=${message.messageType}${
    message.timestamp ? ` time=${message.timestamp}` : ""
  }${extra}]`;
}

// skipcq: JS-0067, JS-R1005
async function prepareContent(apiKey: string, messages: LoadedMessage[]) {
  const content: Array<Record<string, unknown>> = [{
    type: "text",
    text: systemPrompt,
  }];
  const warnings: string[] = [];
  const processedMediaIds: string[] = [];
  let packetBytes = 0;

  for (const message of messages) {
    if (!MEDIA_TYPES.has(message.messageType)) {
      content.push({
        type: "text",
        text: `${evidenceLabel(message)}\n${message.content || "[empty text]"}`,
      });
      continue;
    }
    if (!message.mediaUrl) {
      warnings.push(
        `${message.providerMessageId}: ${message.messageType} has no retrievable media URL`,
      );
      content.push({
        type: "text",
        text: `${evidenceLabel(message, " media_unavailable=true")}\n${
          message.content || "[media unavailable]"
        }`,
      });
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

      if (message.messageType === "audio") {
        const transcript = await transcribeAudio(apiKey, media);
        content.push({
          type: "text",
          text: `${evidenceLabel(message, " transcript=true")}\n${
            message.content ? `CAPTION: ${message.content}\n` : ""
          }TRANSCRIPT: ${transcript}`,
        });
      } else {
        content.push({
          type: "text",
          text: `${evidenceLabel(message)}${
            message.content ? `\nCAPTION: ${message.content}` : ""
          }`,
        });
        const dataUrl = bytesToDataUrl(media.bytes, media.mime);
        if (message.messageType === "image") {
          content.push({ type: "image_url", image_url: { url: dataUrl } });
        }
        if (message.messageType === "video") {
          content.push({ type: "video_url", video_url: { url: dataUrl } });
        }
        if (message.messageType === "document") {
          content.push({
            type: "file",
            file: {
              filename: `whatsapp-po-${
                message.providerMessageId.slice(-16)
              }.pdf`,
              file_data: dataUrl,
            },
          });
        }
      }
      processedMediaIds.push(message.providerMessageId);
    } catch (error) {
      const code = error instanceof Error
        ? error.message
        : "MEDIA_PROCESSING_FAILED";
      warnings.push(`${message.providerMessageId}: ${code}`);
      content.push({
        type: "text",
        text: `${evidenceLabel(message, " media_processing_failed=true")}\n${
          message.content || "[media could not be interpreted]"
        }`,
      });
    }
  }

  return { content, warnings, processedMediaIds };
}

/** Computes a SHA-256 hex digest for packet content fingerprints. skipcq: JS-0067 */
async function sha256(value: string): Promise<string> {
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(value),
  );
  return [...new Uint8Array(digest)].map((byte) =>
    byte.toString(16).padStart(2, "0")
  ).join("");
}

// skipcq: JS-0067, JS-R1005
async function loadPacket(
  admin: SupabaseClient,
  packetId: string,
): Promise<LoadedMessage[]> {
  const { data: packet, error: packetError } = await admin
    .from("whatsapp_message_packets")
    .select("id")
    .eq("id", packetId)
    .maybeSingle();
  if (packetError || !packet) throw new Error("PACKET_NOT_FOUND");

  const { data, error } = await admin
    .from("whatsapp_messages")
    .select(
      "provider_message_id, content, message_type, media_url, message_timestamp, packet_sequence",
    )
    .eq("packet_id", packetId)
    .eq("direction", "inbound")
    .order("packet_sequence", { ascending: true })
    .limit(MAX_PACKET_MESSAGES + 1);
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

/** Loads only immutable evidence admitted to a governed cross-packet case context. skipcq: JS-0067 */
async function loadCaseContext(
  admin: SupabaseClient,
  caseId: string,
): Promise<LoadedMessage[]> {
  const { data, error } = await admin.rpc("whatsapp_case_context_messages", {
    p_case_id: caseId,
  });
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

/** Loads the single actively governed intelligence knowledge snapshot. skipcq: JS-0067, JS-R1005 */
async function loadActiveKnowledgeSnapshot(
  admin: ReturnType<typeof createClient>,
): Promise<{ id: string; schema_version: string }> {
  const { data, error } = await admin
    .from("whatsapp_intelligence_knowledge_snapshots")
    .select("id, schema_version")
    .eq("lifecycle", "ACTIVE")
    .order("activated_at", { ascending: false })
    .limit(2);
  if (error) {
    throw new Error(
      `KNOWLEDGE_SNAPSHOT_LOAD_FAILED:${safeString(error.message, 120)}`,
    );
  }
  if (!data || data.length !== 1 || !data[0]?.id || !data[0]?.schema_version) {
    throw new Error("KNOWLEDGE_SNAPSHOT_NOT_ACTIVELY_GOVERNED");
  }
  return {
    id: String(data[0].id),
    schema_version: String(data[0].schema_version),
  };
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
  // #82 remains the canonical sanitizer for text, confidence, warnings,
  // explicit facts, order lines, corrections and evidence provenance.
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
      // Expanded #84 taxonomy is advisory. The shared sanitizer has already
      // sanitized all authority-bearing evidence before this overlay.
      intent,
      primary_department: primaryDepartment,
      contributor_departments: contributorDepartments,
      reply_clearance: replyClearance,
      draft_reply: safeString(conclusionRaw.draft_reply, 4000),
      human_review_required: true,
    },
  };
};

// skipcq: JS-0067, JS-R1005
async function callAi(apiKey: string, messages: LoadedMessage[]) {
  const prepared = await prepareContent(apiKey, messages);
  const response = await fetch(CHAT_GATEWAY, {
    method: "POST",
    headers: { "Content-Type": "application/json", "Lovable-API-Key": apiKey },
    signal: AbortSignal.timeout(45_000),
    body: JSON.stringify({
      model: MODEL,
      messages: [{ role: "user", content: prepared.content }],
      response_format: { type: "json_object" },
      max_tokens: 3600,
      temperature: 0,
    }),
  });
  if (!response.ok) throw new Error(`INTERPRETER_PROVIDER_${response.status}`);
  const payload = await response.json() as Record<string, unknown>;
  const choices = Array.isArray(payload.choices) ? payload.choices : [];
  const first = choices[0] && typeof choices[0] === "object"
    ? choices[0] as Record<string, unknown>
    : {};
  const gatewayMessage = first.message && typeof first.message === "object"
    ? first.message as Record<string, unknown>
    : {};
  const raw = safeString(gatewayMessage.content, 50000);
  if (!raw) throw new Error("INTERPRETER_EMPTY_RESPONSE");
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

/** Records governed media completion for one provider message id. skipcq: JS-0067 */
function completeOneMedia(
  admin: SupabaseClient,
  providerId: string,
  fingerprint: string,
): Promise<void> {
  return Promise.resolve(
    admin.rpc("complete_whatsapp_media_processing", {
      p_provider_message_id: providerId,
      p_state: "SUCCEEDED",
      p_attempt_key: `packet-ai:${fingerprint}`,
      p_detail: { worker: "whatsapp-packet-ai-worker", model: MODEL },
    }),
  ).then(({ error }) => {
    if (error) {
      throw new Error(
        `MEDIA_COMPLETION_FAILED:${providerId}:${
          safeString(error.message, 120)
        }`,
      );
    }
  });
}

/** Records governed media completion for all processed evidence ids sequentially. skipcq: JS-0067 */
function completeMediaSequentially(
  admin: SupabaseClient,
  ids: string[],
  fingerprint: string,
): Promise<void> {
  const uniqueIds = [...new Set(ids)];
  return uniqueIds.reduce(
    (pending, providerId) =>
      pending.then(() => completeOneMedia(admin, providerId, fingerprint)),
    Promise.resolve(),
  );
}

/** Materializes a governed communication case for a persisted interpretation. skipcq: JS-0067 */
async function materializeCase(
  admin: SupabaseClient,
  packetId: string,
  interpretationId: string,
): Promise<Record<string, unknown>> {
  const { data, error } = await admin.rpc(
    "whatsapp_materialize_packet_ai_case",
    {
      p_packet_id: packetId,
      p_interpretation_id: interpretationId,
    },
  );
  if (error) throw new Error(`CASE_MATERIALIZATION_FAILED: ${error.message}`);
  return data && typeof data === "object"
    ? data as Record<string, unknown>
    : {};
}

/** Claims one durable dispatch job under a short-lived worker lease. skipcq: JS-0067, JS-R1005 */
async function claimDispatchLease(
  admin: SupabaseClient,
): Promise<DispatchLease | null> {
  const { data, error } = await admin.rpc(
    "claim_whatsapp_packet_ai_dispatch_job",
    {
      p_lease_seconds: 120,
    },
  );
  if (error) {
    throw new Error(`DISPATCH_CLAIM_FAILED:${safeString(error.message, 120)}`);
  }
  if (!data) return null;
  const row = data as Record<string, unknown>;
  const id = safeString(row.id, 80);
  const packetId = safeString(row.packet_id, 80);
  const token = safeString(row.lease_token, 80);
  const revision = Number(row.packet_revision);
  const executionKind = safeString(row.execution_kind, 32);
  const caseId = safeString(row.case_id, 80) || null;
  const contextRevisionRaw = row.context_revision;
  const contextRevision = contextRevisionRaw === null || contextRevisionRaw === undefined
    ? null
    : Number(contextRevisionRaw);
  if (
    !id || !packetId || !token || !Number.isSafeInteger(revision) ||
    revision < 1 || (executionKind !== "PACKET" && executionKind !== "CASE_CONTEXT") ||
    (executionKind === "CASE_CONTEXT" && (!caseId || !Number.isSafeInteger(contextRevision) || contextRevision < 1))
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

/** Proves the worker still holds the authoritative dispatch lease. skipcq: JS-0067 */
async function assertDispatchLease(
  admin: SupabaseClient,
  lease: DispatchLease,
): Promise<void> {
  const { data, error } = await admin.rpc(
    "assert_whatsapp_packet_ai_dispatch_lease",
    {
      p_job_id: lease.id,
      p_lease_token: lease.lease_token,
      p_packet_revision: lease.packet_revision,
    },
  );
  if (error) {
    throw new Error(
      `DISPATCH_LEASE_ASSERT_FAILED:${safeString(error.message, 120)}`,
    );
  }
  if (data === true) return;
  await admin.rpc("release_superseded_whatsapp_packet_ai_dispatch_job", {
    p_job_id: lease.id,
    p_lease_token: lease.lease_token,
    p_claimed_packet_revision: lease.packet_revision,
  });
  throw new Error("DISPATCH_LEASE_SUPERSEDED");
}

/** Marks a dispatch lease complete after governed worker effects succeed. skipcq: JS-0067 */
async function completeDispatchLease(
  admin: SupabaseClient,
  lease: DispatchLease,
): Promise<void> {
  try {
    const { data, error } = await admin.rpc(
      "complete_whatsapp_packet_ai_dispatch_job",
      {
        p_job_id: lease.id,
        p_lease_token: lease.lease_token,
        p_packet_revision: lease.packet_revision,
      },
    );
    if (error || data !== true) {
      throw new Error("DISPATCH_COMPLETE_FAILED");
    }
  } catch (dispatchCompleteError) {
    if (
      dispatchCompleteError instanceof Error &&
      dispatchCompleteError.message === "DISPATCH_COMPLETE_FAILED"
    ) {
      throw dispatchCompleteError;
    }
    const detail = dispatchCompleteError instanceof Error
      ? safeString(dispatchCompleteError.message, 120)
      : "UNKNOWN";
    throw new Error(`DISPATCH_COMPLETE_FAILED:${detail}`);
  }
}

/** Records a bounded retry for a failed dispatch lease without guessing outcomes. skipcq: JS-0067 */
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
  await admin.rpc("retry_whatsapp_packet_ai_dispatch_job", {
    p_job_id: lease.id,
    p_lease_token: lease.lease_token,
    p_packet_revision: lease.packet_revision,
    p_error_code: code,
    p_error_detail: error instanceof Error ? error.message.slice(0, 500) : "",
    p_knowledge_authority_failure: knowledge,
  });
}

// skipcq: JS-0067, JS-R1005
async function handleRequest(req: Request): Promise<Response> {
  if (req.method !== "POST") {
    return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }
  const serviceRoleKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
  const authorization = req.headers.get("Authorization") ?? "";
  if (!serviceRoleKey || authorization !== `Bearer ${serviceRoleKey}`) {
    return respond(
      { success: false, error: "TRUSTED_PROCESSOR_REQUIRED" },
      401,
    );
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const apiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!supabaseUrl || !apiKey) {
    return respond({ success: false, error: "WORKER_NOT_CONFIGURED" }, 503);
  }
  const admin = createClient(supabaseUrl, serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const body = await req.json().catch(() => ({})) as Record<string, unknown>;
  const claimNext = body.claim_next === true;
  const lease = claimNext ? await claimDispatchLease(admin) : null;
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
      // Cached interpretations are advisory data, not proof that media was
      // actually fetched/processed. Re-run governed media preparation and
      // complete only the IDs that succeed in this invocation.
      const retried = await prepareContent(apiKey, messages);
      if (lease) await assertDispatchLease(admin, lease);
      await completeMediaSequentially(
        admin,
        retried.processedMediaIds,
        fingerprint,
      );
      if (lease) await assertDispatchLease(admin, lease);
      const caseResult = await materializeCase(
        admin,
        packetId,
        String(existing.id),
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

    const result = await callAi(apiKey, messages);

    if (lease) await assertDispatchLease(admin, lease);

    // Completion is an authority-side effect. It must succeed before the
    // advisory interpretation becomes a durable successful cache entry.
    await completeMediaSequentially(
      admin,
      result.processedMediaIds,
      fingerprint,
    );
    if (lease) await assertDispatchLease(admin, lease);

    const { data: inserted, error: insertError } = await admin
      .from("whatsapp_packet_ai_interpretations")
      .insert({
        packet_id: packetId,
        content_fingerprint: fingerprint,
        provider_message_ids: providerIds,
        interpretation: result.interpretation,
        model_version: MODEL,
        knowledge_snapshot_id: knowledgeSnapshot.id,
        knowledge_snapshot_schema_version: knowledgeSnapshot.schema_version,
        interpretation_schema_version: INTERPRETATION_SCHEMA_VERSION,
        prompt_policy_version: PROMPT_POLICY_VERSION,
        resolver_policy_version: RESOLVER_POLICY_VERSION,
      })
      .select("id")
      .single();

    if (insertError) {
      const duplicate = insertError.code === "23505" ||
        insertError.message.toLowerCase().includes("duplicate");
      if (!duplicate) {
        throw new Error(
          `INTERPRETATION_PERSIST_FAILED:${
            safeString(insertError.message, 120)
          }`,
        );
      }

      const { data: canonical, error: canonicalError } = await admin
        .from("whatsapp_packet_ai_interpretations")
        .select("id, interpretation")
        .eq("packet_id", packetId)
        .eq("content_fingerprint", fingerprint)
        .single();
      if (canonicalError || !canonical?.id) {
        throw new Error("INTERPRETATION_CANONICAL_REREAD_FAILED");
      }

      if (lease) await assertDispatchLease(admin, lease);
      const caseResult = await materializeCase(
        admin,
        packetId,
        String(canonical.id),
      );
      if (lease) await completeDispatchLease(admin, lease);
      return respond({
        success: true,
        cached: true,
        packet_id: packetId,
        content_fingerprint: fingerprint,
        interpretation: canonical.interpretation,
        communication_case: caseResult,
      });
    }

    if (!inserted?.id) throw new Error("INTERPRETATION_ID_MISSING");

    if (lease) await assertDispatchLease(admin, lease);
    const caseResult = await materializeCase(
      admin,
      packetId,
      String(inserted.id),
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
    if (lease) await retryDispatchLease(admin, lease, error);
    throw error;
  }
}

if (import.meta.main) {
  serve((req) =>
    handleRequest(req).catch((error) => {
      const code = error instanceof Error ? error.message : "PACKET_AI_FAILED";
      console.error("[whatsapp-packet-ai-worker]", code.slice(0, 240));
      return respond({ success: false, error: code.slice(0, 240) }, 502);
    })
  );
}

// Test surface for governed media-completion authority (explicit ids only).
export { claimDispatchLease, completeMediaSequentially };
