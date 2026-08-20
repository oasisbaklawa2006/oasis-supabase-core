import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";

const JSON_HEADERS = { "Content-Type": "application/json" };
const MAX_PACKET_MESSAGES = 16;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_MEDIA_BYTES = 15 * 1024 * 1024;
const MAX_PACKET_MEDIA_BYTES = 24 * 1024 * 1024;
const DEFAULT_MEDIA_HOST_SUFFIXES = [
  "click2api.in",
  "lookaside.fbsbx.com",
] as const;
const CHAT_GATEWAY = "https://ai.gateway.lovable.dev/v1/chat/completions";
const TRANSCRIPTION_GATEWAY =
  "https://ai.gateway.lovable.dev/v1/audio/transcriptions";
const MODEL = "google/gemini-3.6-flash";
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
// Fail-closed default when the model returns an unsupported or missing
// reply_clearance value -- deliberately not SAFE_TO_SEND_AUTOMATICALLY.
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

function configuredHosts(): string[] {
  const extra = (Deno.env.get("WHATSAPP_MEDIA_ALLOWED_HOSTS") ?? "")
    .split(",")
    .map((value) => value.trim().toLowerCase().replace(/^\.+/, ""))
    .filter(Boolean);
  return [...new Set([...DEFAULT_MEDIA_HOST_SUFFIXES, ...extra])];
}

export function allowedMediaUrl(value: string): URL {
  let url: URL;
  try {
    url = new URL(value);
  } catch {
    throw new Error("MEDIA_URL_INVALID");
  }
  if (url.protocol !== "https:") {
    throw new Error("MEDIA_URL_PROTOCOL_NOT_ALLOWED");
  }
  if (url.username || url.password) {
    throw new Error("MEDIA_URL_CREDENTIALS_NOT_ALLOWED");
  }
  const host = url.hostname.toLowerCase().replace(/\.$/, "");
  if (
    !configuredHosts().some((suffix) =>
      host === suffix || host.endsWith(`.${suffix}`)
    )
  ) {
    throw new Error("MEDIA_HOST_NOT_ALLOWED");
  }
  return url;
}

function isClick2ApiHost(host: string): boolean {
  return host === "click2api.in" || host.endsWith(".click2api.in");
}

export async function readBoundedBody(
  response: Response,
  maxBytes: number,
): Promise<Uint8Array> {
  if (!response.body) throw new Error("EMPTY_MEDIA");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  try {
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      if (!value?.byteLength) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel("MEDIA_TOO_LARGE").catch(() => undefined);
        throw new Error("MEDIA_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (!total) throw new Error("EMPTY_MEDIA");
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
}

async function downloadMedia(
  urlValue: string,
  maxBytes: number,
): Promise<MediaPayload> {
  const url = allowedMediaUrl(urlValue);
  const headers: Record<string, string> = {};
  if (isClick2ApiHost(url.hostname.toLowerCase())) {
    const apiKey = Deno.env.get("CLICK2API_API_KEY");
    const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
    if (apiKey) headers.apikey = apiKey;
    if (accessToken) headers.Authorization = `Bearer ${accessToken}`;
  }
  const response = await fetch(url.toString(), {
    headers,
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  });
  if (response.status >= 300 && response.status < 400) {
    throw new Error("MEDIA_REDIRECT_NOT_ALLOWED");
  }
  if (!response.ok) throw new Error(`MEDIA_DOWNLOAD_${response.status}`);
  const declared = Number(response.headers.get("content-length"));
  if (Number.isFinite(declared) && declared > maxBytes) {
    throw new Error("MEDIA_TOO_LARGE");
  }
  const mime =
    (response.headers.get("content-type") || "application/octet-stream").split(
      ";",
    )[0].trim().toLowerCase();
  const bytes = await readBoundedBody(response, maxBytes);
  return { bytes, mime };
}

export function validateMime(type: string, mime: string): void {
  if (type === "image" && !IMAGE_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_IMAGE_TYPE");
  }
  if (type === "audio" && !AUDIO_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_AUDIO_TYPE");
  }
  if (type === "video" && !VIDEO_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_VIDEO_TYPE");
  }
  if (type === "document" && !DOCUMENT_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_DOCUMENT_TYPE");
  }
}

function maxBytes(type: string): number {
  return type === "image" ? MAX_IMAGE_BYTES : MAX_MEDIA_BYTES;
}

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

function audioExtension(mime: string): string {
  if (mime.includes("mpeg") || mime.includes("mp3")) return "mp3";
  if (mime.includes("m4a") || mime === "audio/mp4") return "m4a";
  if (mime.includes("ogg")) return "ogg";
  if (mime.includes("wav")) return "wav";
  if (mime.includes("webm")) return "webm";
  return "audio";
}

async function transcribeAudio(
  apiKey: string,
  media: MediaPayload,
): Promise<string> {
  const form = new FormData();
  form.append(
    "file",
    new Blob([media.bytes], { type: media.mime }),
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

function evidenceLabel(message: LoadedMessage, extra = ""): string {
  return `[evidence provider_message_id=${message.providerMessageId} type=${message.messageType}${
    message.timestamp ? ` time=${message.timestamp}` : ""
  }${extra}]`;
}

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
      const media = await downloadMedia(
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

export function validateEvidenceIds(
  ids: string[],
  allowedIds: Set<string>,
): string[] {
  for (const id of ids) {
    if (!allowedIds.has(id)) throw new Error("INTERPRETER_INVALID_PROVENANCE");
  }
  return ids;
}

export function sanitizeInterpretation(
  raw: unknown,
  messages: LoadedMessage[],
  infrastructureWarnings: string[],
): Record<string, unknown> {
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
  const summary = safeString(conclusionRaw.summary, 2200);
  const recommendedAction = safeString(conclusionRaw.recommended_action, 1800);
  if (!ALLOWED_INTENTS.has(intent) || !summary || !recommendedAction) {
    throw new Error("INTERPRETER_INVALID_SCHEMA");
  }

  const allowedIds = new Set(
    messages.map((message) => message.providerMessageId),
  );
  const explicitFacts = Array.isArray(conclusionRaw.explicit_facts)
    ? conclusionRaw.explicit_facts.slice(0, 50).flatMap((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        return [];
      }
      const fact = entry as Record<string, unknown>;
      const providerId = safeString(fact.provider_message_id, 240);
      const kind = safeString(fact.kind, 80);
      const value = safeString(fact.value, 600);
      if (!providerId || !kind || !value) return [];
      validateEvidenceIds([providerId], allowedIds);
      return [{ provider_message_id: providerId, kind, value }];
    })
    : [];

  const orderLines = Array.isArray(conclusionRaw.order_lines)
    ? conclusionRaw.order_lines.slice(0, 50).flatMap((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        return [];
      }
      const line = entry as Record<string, unknown>;
      const productName = safeString(line.product_name, 240);
      const sku = safeString(line.sku, 120);
      if (!productName && !sku) return [];
      const rawQuantity = line.quantity;
      const quantity =
        typeof rawQuantity === "number" && Number.isFinite(rawQuantity) &&
          rawQuantity > 0
          ? rawQuantity
          : null;
      const unit = safeString(line.unit, 80);
      const statusRaw = safeString(line.status, 32).toLowerCase();
      const status = statusRaw === "explicit" || statusRaw === "interpreted"
        ? statusRaw
        : "unclear";
      const evidenceIds = validateEvidenceIds(
        safeStringArray(line.evidence_ids, 16, 240),
        allowedIds,
      );
      if (status === "explicit" && evidenceIds.length === 0) {
        throw new Error("INTERPRETER_INVALID_PROVENANCE");
      }
      return [{
        product_name: productName,
        sku,
        quantity,
        unit,
        status,
        evidence_ids: evidenceIds,
      }];
    })
    : [];

  const corrections = Array.isArray(conclusionRaw.corrections)
    ? conclusionRaw.corrections.slice(0, 25).flatMap((entry) => {
      if (!entry || typeof entry !== "object" || Array.isArray(entry)) {
        return [];
      }
      const correction = entry as Record<string, unknown>;
      const providerId = safeString(correction.provider_message_id, 240);
      const supersedes = safeString(correction.supersedes, 500);
      const replacement = safeString(correction.replacement, 500);
      if (!providerId || !replacement) return [];
      validateEvidenceIds([providerId], allowedIds);
      return [{ provider_message_id: providerId, supersedes, replacement }];
    })
    : [];

  const confidenceRaw = Number(obj.confidence);
  const confidence = Number.isFinite(confidenceRaw)
    ? Math.max(0, Math.min(1, confidenceRaw))
    : 0;
  const warnings = [
    ...new Set([
      ...safeStringArray(obj.warnings, 20, 320),
      ...infrastructureWarnings.map((warning) => warning.slice(0, 320)),
    ]),
  ].slice(0, 24);

  // Advisory routing fields (Central issue #368 migration-train normalization,
  // PROCEED phase 2A section D). Unsupported values fail closed rather than
  // passing through unvalidated model output: an unrecognized department is
  // dropped/blanked (routes to human triage, not a fabricated department),
  // and an unrecognized reply_clearance falls back to the most conservative
  // review gate, never to SAFE_TO_SEND_AUTOMATICALLY.
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

  const draftReply = safeString(conclusionRaw.draft_reply, 4000);

  return {
    normalized_text: safeString(obj.normalized_text, 12000),
    extracted_text: safeString(obj.extracted_text, 12000),
    language: safeString(obj.language, 120) || "unknown",
    confidence,
    warnings,
    source_kind: "packet",
    conclusion: {
      intent,
      summary,
      explicit_facts: explicitFacts,
      order_lines: orderLines,
      corrections,
      ambiguities: safeStringArray(conclusionRaw.ambiguities, 25, 500),
      primary_department: primaryDepartment,
      contributor_departments: contributorDepartments,
      reply_clearance: replyClearance,
      draft_reply: draftReply,
      recommended_action: recommendedAction,
      // SAFE_TO_SEND_AUTOMATICALLY (or any reply_clearance value) is advisory
      // data only -- it never itself authorizes a provider send. Human
      // decision remains a permanent business-authority boundary for the
      // current B2B phase.
      human_review_required: true,
    },
  };
}

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

export function inferredProcessedMediaIds(
  messages: LoadedMessage[],
  interpretation: unknown,
): string[] {
  if (
    !interpretation || typeof interpretation !== "object" ||
    Array.isArray(interpretation)
  ) return [];
  const warnings = safeStringArray(
    (interpretation as Record<string, unknown>).warnings,
    24,
    320,
  );
  return messages
    .filter((message) =>
      MEDIA_TYPES.has(message.messageType) && Boolean(message.mediaUrl)
    )
    .filter((message) =>
      !warnings.some((warning) =>
        warning.startsWith(`${message.providerMessageId}: `)
      )
    )
    .map((message) => message.providerMessageId);
}

async function completeMedia(
  admin: SupabaseClient,
  ids: string[],
  fingerprint: string,
): Promise<void> {
  for (const providerId of [...new Set(ids)]) {
    const { error } = await admin.rpc("complete_whatsapp_media_processing", {
      p_provider_message_id: providerId,
      p_state: "SUCCEEDED",
      p_attempt_key: `packet-ai:${fingerprint}`,
      p_detail: { worker: "whatsapp-packet-ai-worker", model: MODEL },
    });
    if (error) {
      throw new Error(
        `MEDIA_COMPLETION_FAILED:${providerId}:${
          safeString(error.message, 120)
        }`,
      );
    }
  }
}

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

// Only start the HTTP listener when this module is the actual entrypoint
// (the Supabase Edge Function runtime invokes it that way). Importing this
// module for unit tests (index.test.ts) must not bind a port or require
// network permission just to reach the pure, exported helper functions.
if (import.meta.main) {
  serve(handleRequest);
}

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

  try {
    const body = await req.json().catch(() => ({})) as Record<string, unknown>;
    const packetId = safeString(body.packet_id, 80);
    if (
      !/^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
        .test(packetId)
    ) {
      return respond({ success: false, error: "PACKET_ID_REQUIRED" }, 400);
    }

    const messages = await loadPacket(admin, packetId);
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
      // Cached path: a prior attempt may have persisted the interpretation
      // but failed to complete media, so completion authority must still be
      // retried/confirmed here -- never return cached success on its own.
      await completeMedia(
        admin,
        inferredProcessedMediaIds(messages, existing.interpretation),
        fingerprint,
      );
      const caseResult = await materializeCase(
        admin,
        packetId,
        String(existing.id),
      );
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

    // Completion is an authority-side effect. It must succeed before the
    // advisory interpretation becomes a durable successful cache entry, so a
    // retry can never skip a failed completion.
    await completeMedia(admin, result.processedMediaIds, fingerprint);

    const { data: inserted, error: insertError } = await admin
      .from("whatsapp_packet_ai_interpretations")
      .insert({
        packet_id: packetId,
        content_fingerprint: fingerprint,
        provider_message_ids: providerIds,
        interpretation: result.interpretation,
        model_version: MODEL,
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

      // Duplicate race: completeMedia above already ran (idempotently) for
      // this attempt. Another attempt won the insert, so reread the
      // canonical row rather than trusting this attempt's own unsaved
      // interpretation, and materialize the case against the canonical id.
      const { data: canonical, error: canonicalError } = await admin
        .from("whatsapp_packet_ai_interpretations")
        .select("id, interpretation")
        .eq("packet_id", packetId)
        .eq("content_fingerprint", fingerprint)
        .single();
      if (canonicalError || !canonical?.id) {
        throw new Error("INTERPRETATION_CANONICAL_REREAD_FAILED");
      }

      const caseResult = await materializeCase(
        admin,
        packetId,
        String(canonical.id),
      );
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

    const caseResult = await materializeCase(
      admin,
      packetId,
      String(inserted.id),
    );
    return respond({
      success: true,
      packet_id: packetId,
      content_fingerprint: fingerprint,
      interpretation: result.interpretation,
      communication_case: caseResult,
    });
  } catch (error) {
    const code = error instanceof Error ? error.message : "PACKET_AI_FAILED";
    console.error("[whatsapp-packet-ai-worker]", code.slice(0, 240));
    return respond({ success: false, error: code.slice(0, 240) }, 502);
  }
}
