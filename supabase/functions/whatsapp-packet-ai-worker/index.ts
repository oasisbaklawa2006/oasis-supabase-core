/** @file Trusted WhatsApp packet AI worker for governed B2B interpretation. */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import { downloadGovernedWhatsAppMedia } from "../_shared/whatsappGovernedMediaFetch.ts";

const JSON_HEADERS = { "Content-Type": "application/json" };
const MAX_PACKET_MESSAGES = 16;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_MEDIA_BYTES = 15 * 1024 * 1024;
const MAX_PACKET_MEDIA_BYTES = 24 * 1024 * 1024;
const CHAT_GATEWAY = "https://ai.gateway.lovable.dev/v1/chat/completions";
const TRANSCRIPTION_GATEWAY =
  "https://ai.gateway.lovable.dev/v1/audio/transcriptions";
const MODEL = "google/gemini-3.6-flash";
const TRANSCRIPTION_MODEL = "openai/gpt-4o-mini-transcribe";
const MEDIA_TYPES = new Set(["image", "audio", "video", "document"]);
const ALLOWED_INTENTS = new Set([
  "NEW_ORDER",
  "AMENDMENT",
  "ENQUIRY",
  "COMPLAINT",
  "FINANCE",
  "OTHER",
  "UNCLEAR",
]);

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

type LoadedMessage = {
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

Return JSON only:
{
  "normalized_text":"...",
  "extracted_text":"...",
  "language":"...",
  "confidence":0.0,
  "warnings":[],
  "source_kind":"packet",
  "conclusion":{
    "intent":"NEW_ORDER|AMENDMENT|ENQUIRY|COMPLAINT|FINANCE|OTHER|UNCLEAR",
    "summary":"...",
    "explicit_facts":[{"provider_message_id":"...","kind":"...","value":"..."}],
    "order_lines":[{"product_name":"...","sku":"","quantity":null,"unit":"","status":"explicit|interpreted|unclear","evidence_ids":["..."]}],
    "corrections":[{"provider_message_id":"...","supersedes":"...","replacement":"..."}],
    "ambiguities":[],
    "recommended_action":"...",
    "human_review_required":true
  }
}`;

const MIME_ALLOWLIST_BY_TYPE = new Map<string, Set<string>>([
  ["image", IMAGE_MIME],
  ["audio", AUDIO_MIME],
  ["video", VIDEO_MIME],
  ["document", DOCUMENT_MIME],
]);

// skipcq: JS-R1005
const validateMime = (type: string, mime: string): void => {
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

const AUDIO_EXTENSION_HINTS: ReadonlyArray<[string, string]> = [
  ["mpeg", "mp3"],
  ["mp3", "mp3"],
  ["m4a", "m4a"],
  ["ogg", "ogg"],
  ["wav", "wav"],
  ["webm", "webm"],
];

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

/** Hashes packet evidence for idempotent interpretation caching. skipcq: JS-0067 */
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

/** Validates provenance ids against the packet evidence allowlist. skipcq: JS-0067 */
function validateEvidenceIds(ids: string[], allowedIds: Set<string>): string[] {
  for (const id of ids) {
    if (!allowedIds.has(id)) throw new Error("INTERPRETER_INVALID_PROVENANCE");
  }
  return ids;
}

// skipcq: JS-0067, JS-R1005
function sanitizeInterpretation(
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
      recommended_action: recommendedAction,
      human_review_required: true,
    },
  };
}

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
      max_tokens: 3200,
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
async function completeOneMedia(
  admin: SupabaseClient,
  providerId: string,
  fingerprint: string,
): Promise<void> {
  try {
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
  } catch (error) {
    if (error instanceof Error) throw error;
    throw new Error(`MEDIA_COMPLETION_FAILED:${providerId}:unknown`);
  }
}

/** Records governed media completion for all processed evidence ids. skipcq: JS-0067 */
async function completeMedia(
  admin: SupabaseClient,
  ids: string[],
  fingerprint: string,
): Promise<void> {
  const uniqueIds = [...new Set(ids)];
  for (const providerId of uniqueIds) {
    await completeOneMedia(admin, providerId, fingerprint);
  }
}

// skipcq: JS-0067, JS-R1005
async function handlePacketAiRequest(req: Request): Promise<Response> {
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
      // Cached advisory warnings are model-authored/truncated and are never an
      // authority signal for media success. Retry the bounded media-preparation
      // stage and complete only IDs that actually succeed in this invocation.
      const retried = await prepareContent(apiKey, messages);
      await completeMedia(admin, retried.processedMediaIds, fingerprint);
      return respond({
        success: true,
        cached: true,
        packet_id: packetId,
        interpretation: existing.interpretation,
      });
    }

    const result = await callAi(apiKey, messages);

    // Completion is an authority-side effect. It must succeed before the advisory
    // interpretation is cached so a retry can never skip a failed completion.
    await completeMedia(admin, result.processedMediaIds, fingerprint);

    const { error: insertError } = await admin.from(
      "whatsapp_packet_ai_interpretations",
    ).insert({
      packet_id: packetId,
      content_fingerprint: fingerprint,
      provider_message_ids: providerIds,
      interpretation: result.interpretation,
      model_version: MODEL,
    });
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
        .select("interpretation")
        .eq("packet_id", packetId)
        .eq("content_fingerprint", fingerprint)
        .single();
      if (canonicalError || !canonical) {
        throw new Error("INTERPRETATION_CANONICAL_REREAD_FAILED");
      }
      return respond({
        success: true,
        cached: true,
        packet_id: packetId,
        content_fingerprint: fingerprint,
        interpretation: canonical.interpretation,
      });
    }

    return respond({
      success: true,
      packet_id: packetId,
      content_fingerprint: fingerprint,
      interpretation: result.interpretation,
    });
}

serve((req) =>
  handlePacketAiRequest(req).catch((error) => {
    const code = error instanceof Error ? error.message : "PACKET_AI_FAILED";
    console.error("[whatsapp-packet-ai-worker]", code.slice(0, 240));
    return respond({ success: false, error: code.slice(0, 240) }, 502);
  }),
);
