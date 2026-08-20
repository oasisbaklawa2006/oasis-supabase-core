/** @file Authenticated WhatsApp B2B multimodal evidence interpretation handler. */
import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import { downloadGovernedWhatsAppMedia } from "../_shared/whatsappGovernedMediaFetch.ts";
import {
  type InterpretResponse,
  sanitizeInterpretResult,
  statusForInterpretationError,
} from "./sanitize.ts";
import type {
  InboundMessageRow,
  LoadedMessage,
  RequestIds,
  SourceKind,
} from "./types.ts";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers":
    "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const MAX_PACKET_MESSAGES = 16;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_AUDIO_BYTES = 15 * 1024 * 1024;
const MAX_VIDEO_BYTES = 15 * 1024 * 1024;
const MAX_DOCUMENT_BYTES = 15 * 1024 * 1024;
const MAX_PACKET_MEDIA_BYTES = 24 * 1024 * 1024;
const LOVABLE_CHAT_GATEWAY =
  "https://ai.gateway.lovable.dev/v1/chat/completions";
const LOVABLE_TRANSCRIPTION_GATEWAY =
  "https://ai.gateway.lovable.dev/v1/audio/transcriptions";
const INTERPRETER_MODEL = "google/gemini-3.6-flash";
const TRANSCRIPTION_MODEL = "openai/gpt-4o-mini-transcribe";

const SUPPORTED_IMAGE_MIME = new Set([
  "image/jpeg",
  "image/png",
  "image/webp",
  "image/gif",
]);
const SUPPORTED_AUDIO_MIME = new Set([
  "audio/mpeg",
  "audio/mp3",
  "audio/mp4",
  "audio/x-m4a",
  "audio/ogg",
  "audio/wav",
  "audio/x-wav",
  "audio/webm",
]);
const SUPPORTED_VIDEO_MIME = new Set([
  "video/mp4",
  "video/webm",
  "video/quicktime",
]);
const SUPPORTED_DOCUMENT_MIME = new Set(["application/pdf"]);

const respond = (body: Record<string, unknown>, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });

const safeString = (value: unknown, max: number): string =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

const bytesToBase64 = (bytes: Uint8Array): string => {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(
      offset,
      Math.min(offset + chunkSize, bytes.length),
    );
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
};

const toDataUrl = (bytes: Uint8Array, mime: string): string =>
  `data:${mime};base64,${bytesToBase64(bytes)}`;

const buildSystemPrompt = (): string =>
  `You are the B2B WhatsApp evidence interpreter and decision-support engine for Oasis Baklawa.

Your job is to understand the ENTIRE supplied WhatsApp evidence packet before an authorised human makes a business decision. Inputs may be clean or badly typed English, Hindi in Devanagari, Roman Hinglish, phonetic spelling, abbreviations, misspellings, photographs, screenshots, handwriting, voice-note transcripts, videos, and PDF purchase orders. Treat all modalities as evidence belonging to one chronological packet.

Rules:
1. Preserve provenance. Every explicit fact and correction must cite the provider_message_id that supports it.
2. Understand obvious spelling/typing/transliteration variants, but never invent an unsupported product, SKU, quantity, unit, price, customer, payment status, delivery date, stock position, credit approval or promise.
3. Later explicit corrections supersede earlier conflicting instructions. Record that in corrections; never silently erase the earlier evidence.
4. A PDF PO may contain structured rows, PO number, quantities, units, dates and delivery instructions. Extract only what is actually present.
5. Images may be handwritten or photographed documents/products. Read only visible facts. If illegible, mark ambiguity rather than guessing.
6. Voice/video may contain Hindi, English or Hinglish. Use the supplied transcript and/or video evidence exactly as evidence, not as authority to invent missing details.
7. Distinguish explicit facts from interpreted catalogue-style normalization. If a product phrase is approximate, set the order-line status to interpreted or unclear.
8. AI must reach a concise reasoned B2B conclusion and recommended next action, but the final commercial decision is HUMAN. Set human_review_required=true whenever there is ambiguity, correction, inferred matching, missing evidence, or any commitment-bearing action.
9. Do not create, approve or promise anything. This output is advisory evidence interpretation only.
10. normalized_text must be a concise chronological text rendering suitable for downstream Oasis product/quantity resolution. Include explicit corrections and quantities. Do not include invented facts.

Return JSON only with this shape:
{
  "normalized_text": "chronological normalized evidence text",
  "extracted_text": "faithful compact rendering of readable/transcribed source evidence",
  "language": "detected language(s)",
  "confidence": 0.0,
  "warnings": [],
  "conclusion": {
    "intent": "NEW_ORDER|AMENDMENT|ENQUIRY|COMPLAINT|FINANCE|OTHER|UNCLEAR",
    "summary": "what the packet most probably means",
    "explicit_facts": [{"provider_message_id":"...","kind":"product|quantity|po_number|date|customer_statement|other","value":"..."}],
    "order_lines": [{"product_name":"...","sku":"","quantity":null,"unit":"","status":"explicit|interpreted|unclear","evidence_ids":["..."]}],
    "corrections": [{"provider_message_id":"...","supersedes":"...","replacement":"..."}],
    "ambiguities": [],
    "recommended_action": "exact next human action",
    "human_review_required": true
  }
}`;

const gatewayError = (status: number): Error => {
  if (status === 429) return new Error("INTERPRETER_PROVIDER_RATE_LIMITED");
  if (status === 402) {
    return new Error("INTERPRETER_PROVIDER_CREDITS_EXHAUSTED");
  }
  if (status === 401 || status === 403) {
    return new Error("INTERPRETER_PROVIDER_AUTH_FAILED");
  }
  return new Error(`INTERPRETER_PROVIDER_${status}`);
};

const assertSupportedMime = (messageType: string, mime: string): void => {
  if (messageType === "image" && !SUPPORTED_IMAGE_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_IMAGE_TYPE");
  }
  if (messageType === "audio" && !SUPPORTED_AUDIO_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_AUDIO_TYPE");
  }
  if (messageType === "video" && !SUPPORTED_VIDEO_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_VIDEO_TYPE");
  }
  if (messageType === "document" && !SUPPORTED_DOCUMENT_MIME.has(mime)) {
    throw new Error("UNSUPPORTED_DOCUMENT_TYPE");
  }
};

const maxBytesForMessageType = (messageType: string): number => {
  if (messageType === "image") return MAX_IMAGE_BYTES;
  if (messageType === "audio") return MAX_AUDIO_BYTES;
  if (messageType === "video") return MAX_VIDEO_BYTES;
  if (messageType === "document") return MAX_DOCUMENT_BYTES;
  return 0;
};

const AUDIO_MIME_EXTENSIONS = new Map<string, string>([
  ["audio/mpeg", "mp3"],
  ["audio/mp3", "mp3"],
  ["audio/mp4", "m4a"],
  ["audio/x-m4a", "m4a"],
  ["audio/ogg", "ogg"],
  ["audio/wav", "wav"],
  ["audio/x-wav", "wav"],
  ["audio/webm", "webm"],
]);

const extensionForMime = (mime: string): string =>
  AUDIO_MIME_EXTENSIONS.get(mime) ?? "audio";

const transcribeAudio = async (
  apiKey: string,
  media: { bytes: Uint8Array; mime: string },
): Promise<string> => {
  const form = new FormData();
  form.append(
    "file",
    new Blob([media.bytes], { type: media.mime }),
    `whatsapp-voice.${extensionForMime(media.mime)}`,
  );
  form.append("model", TRANSCRIPTION_MODEL);
  const response = await fetch(LOVABLE_TRANSCRIPTION_GATEWAY, {
    method: "POST",
    signal: AbortSignal.timeout(30_000),
    headers: { "Lovable-API-Key": apiKey },
    body: form,
  });
  if (!response.ok) throw gatewayError(response.status);
  const payload = await response.json() as Record<string, unknown>;
  if (payload.error) throw new Error("INTERPRETER_PROVIDER_UPSTREAM_ERROR");
  const transcript = safeString(payload.text, 10000);
  if (!transcript) throw new Error("AUDIO_TRANSCRIPTION_EMPTY");
  return transcript;
};

const parseRequestIds = async (req: Request): Promise<RequestIds | null> => {
  try {
    const body = await req.json() as Record<string, unknown>;
    const plural = Array.isArray(body.provider_message_ids)
      ? body.provider_message_ids.filter((value): value is string =>
        typeof value === "string"
      )
      : [];
    const singular = typeof body.provider_message_id === "string"
      ? body.provider_message_id
      : "";
    const rawIds = plural.length > 0 ? plural : singular ? [singular] : [];
    const ids = [...new Set(rawIds.map((id) => id.trim()).filter(Boolean))];
    if (ids.length === 0) return null;
    return { ids, packetMode: plural.length > 0 };
  } catch {
    return null;
  }
};

const createScopedClient = (authorization: string): SupabaseClient | null => {
  const supabaseUrl = Deno.env.get("SUPABASE_URL");
  const anonKey = Deno.env.get("SUPABASE_ANON_KEY");
  if (!supabaseUrl || !anonKey) return null;
  return createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
};

const rowToMessage = (
  providerMessageId: string,
  row: InboundMessageRow,
): LoadedMessage => ({
  providerMessageId,
  sourceText: typeof row.content === "string" ? row.content : "",
  messageType: typeof row.message_type === "string"
    ? row.message_type.toLowerCase()
    : "text",
  mediaUrl: typeof row.media_url === "string" ? row.media_url : "",
  messageTimestamp: typeof row.message_timestamp === "string"
    ? row.message_timestamp
    : "",
});

const loadInboundMessages = async (
  scoped: SupabaseClient,
  requestedIds: string[],
): Promise<{ messages: LoadedMessage[] | null; error: string | null }> => {
  const { data, error } = await scoped
    .from("whatsapp_messages")
    .select(
      "provider_message_id, content, message_type, media_url, message_timestamp, direction",
    )
    .in("provider_message_id", requestedIds)
    .eq("direction", "inbound");
  if (error) return { messages: null, error: "MESSAGE_LOOKUP_FAILED" };

  const byId = new Map<string, InboundMessageRow>();
  for (const row of (data ?? []) as InboundMessageRow[]) {
    if (typeof row.provider_message_id === "string") {
      byId.set(row.provider_message_id, row);
    }
  }
  if (requestedIds.some((id) => !byId.has(id))) {
    return { messages: null, error: "MESSAGE_NOT_FOUND_OR_FORBIDDEN" };
  }

  const messages: LoadedMessage[] = [];
  for (const id of requestedIds) {
    const row = byId.get(id);
    if (!row) {
      return { messages: null, error: "MESSAGE_NOT_FOUND_OR_FORBIDDEN" };
    }
    messages.push(rowToMessage(id, row));
  }
  return { messages, error: null };
};

const labelForEvidence = (message: LoadedMessage, suffix = ""): string => {
  const timestamp = message.messageTimestamp
    ? ` time=${message.messageTimestamp}`
    : "";
  return `[evidence provider_message_id=${message.providerMessageId} type=${message.messageType}${timestamp}${suffix}]`;
};

const appendTextEvidence = (
  content: Array<Record<string, unknown>>,
  message: LoadedMessage,
  suffix: string,
  body: string,
): void => {
  content.push({
    type: "text",
    text: `${labelForEvidence(message, suffix)}\n${body}`,
  });
};

const appendMediaEvidence = (
  content: Array<Record<string, unknown>>,
  message: LoadedMessage,
  media: { bytes: Uint8Array; mime: string },
): void => {
  const dataUrl = toDataUrl(media.bytes, media.mime);
  if (message.messageType === "image") {
    content.push({ type: "image_url", image_url: { url: dataUrl } });
  } else if (message.messageType === "video") {
    content.push({ type: "video_url", video_url: { url: dataUrl } });
  } else {
    content.push({
      type: "file",
      file: {
        filename: `whatsapp-po-${message.providerMessageId.slice(-16)}.pdf`,
        file_data: dataUrl,
      },
    });
  }
};

const prepareMultimodalContent = async (
  apiKey: string,
  messages: LoadedMessage[],
): Promise<{ content: Array<Record<string, unknown>>; warnings: string[] }> => {
  const content: Array<Record<string, unknown>> = [{
    type: "text",
    text: buildSystemPrompt(),
  }];
  const warnings: string[] = [];
  let totalMediaBytes = 0;
  const mediaTypes = new Set(["image", "audio", "video", "document"]);

  for (const message of messages) {
    const sourceText = message.sourceText.slice(0, 6000);
    const isPlainText = message.messageType === "text" ||
      !mediaTypes.has(message.messageType);
    if (isPlainText) {
      appendTextEvidence(content, message, "", sourceText || "[empty text]");
      continue;
    }

    if (!message.mediaUrl) {
      warnings.push(
        `${message.providerMessageId}: ${message.messageType} evidence has no retrievable media URL; human review required`,
      );
      appendTextEvidence(
        content,
        message,
        " media_unavailable=true",
        sourceText || "[media unavailable]",
      );
      continue;
    }

    const media = await downloadGovernedWhatsAppMedia(
      message.mediaUrl,
      maxBytesForMessageType(message.messageType),
    );
    assertSupportedMime(message.messageType, media.mime);
    totalMediaBytes += media.bytes.byteLength;
    if (totalMediaBytes > MAX_PACKET_MEDIA_BYTES) {
      throw new Error("PACKET_MEDIA_TOO_LARGE");
    }

    if (message.messageType === "audio") {
      const transcript = await transcribeAudio(apiKey, media);
      const caption = sourceText ? `CAPTION: ${sourceText}\n` : "";
      appendTextEvidence(
        content,
        message,
        " transcript=true",
        `${caption}TRANSCRIPT: ${transcript}`,
      );
      continue;
    }

    appendTextEvidence(
      content,
      message,
      "",
      sourceText ? `CAPTION: ${sourceText}` : "",
    );
    appendMediaEvidence(content, message, media);
  }

  return { content, warnings };
};

const sourceKindForMessages = (
  messages: LoadedMessage[],
  packetMode: boolean,
): SourceKind => {
  if (packetMode || messages.length !== 1) return "packet";
  const kind = messages[0].messageType;
  if (
    kind === "image" || kind === "audio" || kind === "video" ||
    kind === "document"
  ) return kind;
  return "text";
};

const callPacketInterpreter = async (
  apiKey: string,
  messages: LoadedMessage[],
  packetMode: boolean,
): Promise<InterpretResponse> => {
  const prepared = await prepareMultimodalContent(apiKey, messages);
  const response = await fetch(LOVABLE_CHAT_GATEWAY, {
    method: "POST",
    signal: AbortSignal.timeout(45_000),
    headers: { "Content-Type": "application/json", "Lovable-API-Key": apiKey },
    body: JSON.stringify({
      model: INTERPRETER_MODEL,
      messages: [{ role: "user", content: prepared.content }],
      response_format: { type: "json_object" },
      max_tokens: 3200,
      temperature: 0,
    }),
  });
  if (!response.ok) throw gatewayError(response.status);

  const payload = await response.json() as Record<string, unknown>;
  if (payload.error) throw new Error("INTERPRETER_PROVIDER_UPSTREAM_ERROR");
  const choices = Array.isArray(payload.choices) ? payload.choices : [];
  const first = choices[0] && typeof choices[0] === "object"
    ? choices[0] as Record<string, unknown>
    : {};
  const message = first.message && typeof first.message === "object"
    ? first.message as Record<string, unknown>
    : {};
  const rawContent = safeString(message.content, 50000);
  if (!rawContent) throw new Error("INTERPRETER_EMPTY_RESPONSE");

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawContent);
  } catch {
    throw new Error("INTERPRETER_INVALID_JSON");
  }

  return sanitizeInterpretResult(
    parsed,
    sourceKindForMessages(messages, packetMode),
    prepared.warnings,
    new Set(messages.map((entry) => entry.providerMessageId)),
  );
};

const handleRequest = async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: CORS_HEADERS });
  }
  if (req.method !== "POST") {
    return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);
  }

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) {
    return respond({ success: false, error: "AUTH_REQUIRED" }, 401);
  }
  const scoped = createScopedClient(authorization);
  if (!scoped) {
    return respond({ success: false, error: "SUPABASE_CONFIG_MISSING" }, 500);
  }

  const { data: authData, error: authError } = await scoped.auth.getUser();
  if (authError || !authData.user) {
    return respond({ success: false, error: "AUTH_INVALID" }, 401);
  }

  const requestIds = await parseRequestIds(req);
  if (!requestIds) {
    return respond(
      { success: false, error: "PROVIDER_MESSAGE_ID_REQUIRED" },
      400,
    );
  }
  if (requestIds.ids.length > MAX_PACKET_MESSAGES) {
    return respond(
      { success: false, error: "INTERPRETATION_PACKET_TOO_LARGE" },
      413,
    );
  }

  const loaded = await loadInboundMessages(scoped, requestIds.ids);
  if (loaded.error === "MESSAGE_LOOKUP_FAILED") {
    return respond({ success: false, error: loaded.error }, 500);
  }
  if (!loaded.messages) {
    return respond({
      success: false,
      error: loaded.error ?? "MESSAGE_NOT_FOUND_OR_FORBIDDEN",
    }, 404);
  }

  const apiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!apiKey) {
    return respond(
      { success: false, error: "INTERPRETER_NOT_CONFIGURED" },
      503,
    );
  }

  try {
    const interpretation = await callPacketInterpreter(
      apiKey,
      loaded.messages,
      requestIds.packetMode,
    );
    return respond({ success: true, interpretation });
  } catch (error) {
    const code = error instanceof Error
      ? error.message
      : "INTERPRETATION_FAILED";
    console.error("[whatsapp-content-interpret]", code.slice(0, 160));
    return respond(
      { success: false, error: code.slice(0, 160) },
      statusForInterpretationError(code),
    );
  }
};

serve(handleRequest);
