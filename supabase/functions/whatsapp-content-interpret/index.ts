import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";

const CORS_HEADERS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
  "Content-Type": "application/json",
};

const MAX_PACKET_MESSAGES = 16;
const MAX_IMAGE_BYTES = 8 * 1024 * 1024;
const MAX_AUDIO_BYTES = 15 * 1024 * 1024;
const MAX_VIDEO_BYTES = 15 * 1024 * 1024;
const MAX_DOCUMENT_BYTES = 15 * 1024 * 1024;
const MAX_PACKET_MEDIA_BYTES = 24 * 1024 * 1024;
const DEFAULT_MEDIA_HOST_SUFFIXES = ["click2api.in", "lookaside.fbsbx.com"] as const;
const LOVABLE_CHAT_GATEWAY = "https://ai.gateway.lovable.dev/v1/chat/completions";
const LOVABLE_TRANSCRIPTION_GATEWAY = "https://ai.gateway.lovable.dev/v1/audio/transcriptions";
const INTERPRETER_MODEL = "google/gemini-3.6-flash";
const TRANSCRIPTION_MODEL = "openai/gpt-4o-mini-transcribe";

const SUPPORTED_IMAGE_MIME = new Set(["image/jpeg", "image/png", "image/webp", "image/gif"]);
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
const SUPPORTED_VIDEO_MIME = new Set(["video/mp4", "video/webm", "video/quicktime"]);
const SUPPORTED_DOCUMENT_MIME = new Set(["application/pdf"]);

type SourceKind = "text" | "image" | "audio" | "video" | "document" | "packet";
type ConclusionIntent = "NEW_ORDER" | "AMENDMENT" | "ENQUIRY" | "COMPLAINT" | "FINANCE" | "OTHER" | "UNCLEAR";

type ExplicitFact = {
  provider_message_id: string;
  kind: string;
  value: string;
};

type OrderLine = {
  product_name: string;
  sku: string;
  quantity: number | null;
  unit: string;
  status: "explicit" | "interpreted" | "unclear";
  evidence_ids: string[];
};

type Correction = {
  provider_message_id: string;
  supersedes: string;
  replacement: string;
};

type AiConclusion = {
  intent: ConclusionIntent;
  summary: string;
  explicit_facts: ExplicitFact[];
  order_lines: OrderLine[];
  corrections: Correction[];
  ambiguities: string[];
  recommended_action: string;
  human_review_required: boolean;
};

type InterpretResponse = {
  normalized_text: string;
  extracted_text: string;
  language: string;
  confidence: number;
  warnings: string[];
  source_kind: SourceKind;
  conclusion: AiConclusion;
};

type InboundMessageRow = {
  provider_message_id: string | null;
  content: string | null;
  message_type: string | null;
  media_url: string | null;
  message_timestamp: string | null;
};

type LoadedMessage = {
  providerMessageId: string;
  sourceText: string;
  messageType: string;
  mediaUrl: string;
  messageTimestamp: string;
};

type MediaPayload = {
  bytes: Uint8Array;
  mime: string;
};

type RequestIds = {
  ids: string[];
  packetMode: boolean;
};

const respond = (body: Record<string, unknown>, status = 200): Response =>
  new Response(JSON.stringify(body), { status, headers: CORS_HEADERS });

const safeString = (value: unknown, max: number): string =>
  typeof value === "string" ? value.trim().slice(0, max) : "";

const clampConfidence = (value: unknown): number => {
  const n = Number(value);
  if (!Number.isFinite(n)) return 0;
  return Math.max(0, Math.min(1, n));
};

const sanitizeStringArray = (value: unknown, maxItems: number, maxLength: number): string[] => {
  if (!Array.isArray(value)) return [];
  return value
    .filter((entry): entry is string => typeof entry === "string")
    .map((entry) => entry.trim().slice(0, maxLength))
    .filter(Boolean)
    .slice(0, maxItems);
};

const validateEvidenceIds = (ids: string[], allowedIds: Set<string>): string[] => {
  for (const id of ids) {
    if (!allowedIds.has(id)) throw new Error("INTERPRETER_INVALID_PROVENANCE");
  }
  return ids;
};

const sanitizeIntent = (value: unknown): ConclusionIntent => {
  const candidate = safeString(value, 32).toUpperCase();
  const allowed: ConclusionIntent[] = ["NEW_ORDER", "AMENDMENT", "ENQUIRY", "COMPLAINT", "FINANCE", "OTHER", "UNCLEAR"];
  return allowed.includes(candidate as ConclusionIntent) ? candidate as ConclusionIntent : "UNCLEAR";
};

const sanitizeExplicitFacts = (value: unknown, allowedIds: Set<string>): ExplicitFact[] => {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 50).flatMap((entry) => {
    const obj = entry && typeof entry === "object" ? entry as Record<string, unknown> : null;
    if (!obj) return [];
    const providerMessageId = safeString(obj.provider_message_id, 240);
    const kind = safeString(obj.kind, 80);
    const factValue = safeString(obj.value, 600);
    if (!providerMessageId || !kind || !factValue) return [];
    validateEvidenceIds([providerMessageId], allowedIds);
    return [{ provider_message_id: providerMessageId, kind, value: factValue }];
  });
};

const sanitizeOrderLines = (value: unknown, allowedIds: Set<string>): OrderLine[] => {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 50).flatMap((entry) => {
    const obj = entry && typeof entry === "object" ? entry as Record<string, unknown> : null;
    if (!obj) return [];
    const productName = safeString(obj.product_name, 240);
    const sku = safeString(obj.sku, 120);
    const quantityRaw = obj.quantity;
    const quantity = typeof quantityRaw === "number" && Number.isFinite(quantityRaw) && quantityRaw > 0
      ? quantityRaw
      : null;
    const unit = safeString(obj.unit, 80);
    const rawStatus = safeString(obj.status, 32).toLowerCase();
    const status: OrderLine["status"] = rawStatus === "explicit" || rawStatus === "interpreted"
      ? rawStatus
      : "unclear";
    const evidenceIds = validateEvidenceIds(sanitizeStringArray(obj.evidence_ids, 16, 240), allowedIds);
    if (!productName && !sku) return [];
    if (status === "explicit" && evidenceIds.length === 0) throw new Error("INTERPRETER_INVALID_PROVENANCE");
    return [{ product_name: productName, sku, quantity, unit, status, evidence_ids: evidenceIds }];
  });
};

const sanitizeCorrections = (value: unknown, allowedIds: Set<string>): Correction[] => {
  if (!Array.isArray(value)) return [];
  return value.slice(0, 25).flatMap((entry) => {
    const obj = entry && typeof entry === "object" ? entry as Record<string, unknown> : null;
    if (!obj) return [];
    const providerMessageId = safeString(obj.provider_message_id, 240);
    const supersedes = safeString(obj.supersedes, 500);
    const replacement = safeString(obj.replacement, 500);
    if (!providerMessageId || !replacement) return [];
    validateEvidenceIds([providerMessageId], allowedIds);
    return [{ provider_message_id: providerMessageId, supersedes, replacement }];
  });
};

const sanitizeConclusion = (value: unknown, allowedIds: Set<string>): AiConclusion => {
  const obj = value && typeof value === "object" ? value as Record<string, unknown> : {};
  return {
    intent: sanitizeIntent(obj.intent),
    summary: safeString(obj.summary, 2200),
    explicit_facts: sanitizeExplicitFacts(obj.explicit_facts, allowedIds),
    order_lines: sanitizeOrderLines(obj.order_lines, allowedIds),
    corrections: sanitizeCorrections(obj.corrections, allowedIds),
    ambiguities: sanitizeStringArray(obj.ambiguities, 25, 500),
    recommended_action: safeString(obj.recommended_action, 1800),
    human_review_required: obj.human_review_required !== false,
  };
};

const sanitizeResult = (
  raw: unknown,
  sourceKind: SourceKind,
  infrastructureWarnings: string[],
  allowedIds: Set<string>,
): InterpretResponse => {
  const obj = raw && typeof raw === "object" ? raw as Record<string, unknown> : {};
  const conclusion = sanitizeConclusion(obj.conclusion, allowedIds);
  if (infrastructureWarnings.length > 0) conclusion.human_review_required = true;
  return {
    normalized_text: safeString(obj.normalized_text, 12000),
    extracted_text: safeString(obj.extracted_text, 12000),
    language: safeString(obj.language, 120) || "unknown",
    confidence: clampConfidence(obj.confidence),
    warnings: [...new Set([
      ...sanitizeStringArray(obj.warnings, 20, 320),
      ...infrastructureWarnings.map((warning) => warning.slice(0, 320)),
    ])].slice(0, 24),
    source_kind: sourceKind,
    conclusion,
  };
};

const bytesToBase64 = (bytes: Uint8Array): string => {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    const chunk = bytes.subarray(offset, Math.min(offset + chunkSize, bytes.length));
    binary += String.fromCharCode(...chunk);
  }
  return btoa(binary);
};

const toDataUrl = (bytes: Uint8Array, mime: string): string =>
  `data:${mime};base64,${bytesToBase64(bytes)}`;

const buildSystemPrompt = (): string => `You are the B2B WhatsApp evidence interpreter and decision-support engine for Oasis Baklawa.

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
  if (status === 402) return new Error("INTERPRETER_PROVIDER_CREDITS_EXHAUSTED");
  if (status === 401 || status === 403) return new Error("INTERPRETER_PROVIDER_AUTH_FAILED");
  return new Error(`INTERPRETER_PROVIDER_${status}`);
};

const configuredMediaHostSuffixes = (): string[] => {
  const configured = (Deno.env.get("WHATSAPP_MEDIA_ALLOWED_HOSTS") ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase().replace(/^\.+/, ""))
    .filter(Boolean);
  return [...new Set([...DEFAULT_MEDIA_HOST_SUFFIXES, ...configured])];
};

const parseAllowedMediaUrl = (mediaUrl: string): URL => {
  let parsed: URL;
  try {
    parsed = new URL(mediaUrl);
  } catch {
    throw new Error("MEDIA_URL_INVALID");
  }
  if (parsed.protocol !== "https:") throw new Error("MEDIA_URL_PROTOCOL_NOT_ALLOWED");
  if (parsed.username || parsed.password) throw new Error("MEDIA_URL_CREDENTIALS_NOT_ALLOWED");
  const hostname = parsed.hostname.toLowerCase().replace(/\.$/, "");
  const allowed = configuredMediaHostSuffixes().some(
    (suffix) => hostname === suffix || hostname.endsWith(`.${suffix}`),
  );
  if (!allowed) throw new Error("MEDIA_HOST_NOT_ALLOWED");
  return parsed;
};

const isClick2ApiHost = (hostname: string): boolean =>
  hostname === "click2api.in" || hostname.endsWith(".click2api.in");

const readBoundedBody = async (response: Response, maxBytes: number): Promise<Uint8Array> => {
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
};

const downloadMedia = async (mediaUrl: string, maxBytes: number): Promise<MediaPayload> => {
  const parsed = parseAllowedMediaUrl(mediaUrl);
  const providerHeaders: Record<string, string> = {};
  if (isClick2ApiHost(parsed.hostname.toLowerCase())) {
    const click2ApiKey = Deno.env.get("CLICK2API_API_KEY");
    const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
    if (click2ApiKey) providerHeaders.apikey = click2ApiKey;
    if (accessToken) providerHeaders.Authorization = `Bearer ${accessToken}`;
  }

  const mediaResponse = await fetch(parsed.toString(), {
    headers: providerHeaders,
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  });
  if (mediaResponse.status >= 300 && mediaResponse.status < 400) throw new Error("MEDIA_REDIRECT_NOT_ALLOWED");
  if (!mediaResponse.ok) throw new Error(`MEDIA_DOWNLOAD_${mediaResponse.status}`);

  const declaredLength = Number(mediaResponse.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) throw new Error("MEDIA_TOO_LARGE");

  const mime = (mediaResponse.headers.get("content-type") || "application/octet-stream")
    .split(";")[0]
    .trim()
    .toLowerCase();
  const bytes = await readBoundedBody(mediaResponse, maxBytes);
  return { bytes, mime };
};

const assertSupportedMime = (messageType: string, mime: string): void => {
  if (messageType === "image" && !SUPPORTED_IMAGE_MIME.has(mime)) throw new Error("UNSUPPORTED_IMAGE_TYPE");
  if (messageType === "audio" && !SUPPORTED_AUDIO_MIME.has(mime)) throw new Error("UNSUPPORTED_AUDIO_TYPE");
  if (messageType === "video" && !SUPPORTED_VIDEO_MIME.has(mime)) throw new Error("UNSUPPORTED_VIDEO_TYPE");
  if (messageType === "document" && !SUPPORTED_DOCUMENT_MIME.has(mime)) throw new Error("UNSUPPORTED_DOCUMENT_TYPE");
};

const maxBytesForMessageType = (messageType: string): number => {
  if (messageType === "image") return MAX_IMAGE_BYTES;
  if (messageType === "audio") return MAX_AUDIO_BYTES;
  if (messageType === "video") return MAX_VIDEO_BYTES;
  if (messageType === "document") return MAX_DOCUMENT_BYTES;
  return 0;
};

const extensionForMime = (mime: string): string => {
  const extensions: Record<string, string> = {
    "audio/mpeg": "mp3",
    "audio/mp3": "mp3",
    "audio/mp4": "m4a",
    "audio/x-m4a": "m4a",
    "audio/ogg": "ogg",
    "audio/wav": "wav",
    "audio/x-wav": "wav",
    "audio/webm": "webm",
  };
  return extensions[mime] ?? "audio";
};

const transcribeAudio = async (apiKey: string, media: MediaPayload): Promise<string> => {
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
      ? body.provider_message_ids.filter((value): value is string => typeof value === "string")
      : [];
    const singular = typeof body.provider_message_id === "string" ? body.provider_message_id : "";
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

const loadInboundMessages = async (
  scoped: SupabaseClient,
  requestedIds: string[],
): Promise<{ messages: LoadedMessage[] | null; error: string | null }> => {
  const { data, error } = await scoped
    .from("whatsapp_messages")
    .select("provider_message_id, content, message_type, media_url, message_timestamp, direction")
    .in("provider_message_id", requestedIds)
    .eq("direction", "inbound");
  if (error) return { messages: null, error: "MESSAGE_LOOKUP_FAILED" };

  const byId = new Map<string, InboundMessageRow>();
  for (const row of (data ?? []) as InboundMessageRow[]) {
    if (typeof row.provider_message_id === "string") byId.set(row.provider_message_id, row);
  }
  const missing = requestedIds.filter((id) => !byId.has(id));
  if (missing.length > 0) return { messages: null, error: "MESSAGE_NOT_FOUND_OR_FORBIDDEN" };

  const messages: LoadedMessage[] = [];
  for (const providerMessageId of requestedIds) {
    const row = byId.get(providerMessageId);
    if (!row) return { messages: null, error: "MESSAGE_NOT_FOUND_OR_FORBIDDEN" };
    messages.push({
      providerMessageId,
      sourceText: typeof row.content === "string" ? row.content : "",
      messageType: typeof row.message_type === "string" ? row.message_type.toLowerCase() : "text",
      mediaUrl: typeof row.media_url === "string" ? row.media_url : "",
      messageTimestamp: typeof row.message_timestamp === "string" ? row.message_timestamp : "",
    });
  }
  return { messages, error: null };
};

const labelForEvidence = (message: LoadedMessage, suffix = ""): string => {
  const timestamp = message.messageTimestamp ? ` time=${message.messageTimestamp}` : "";
  return `[evidence provider_message_id=${message.providerMessageId} type=${message.messageType}${timestamp}${suffix}]`;
};

const prepareMultimodalContent = async (
  apiKey: string,
  messages: LoadedMessage[],
): Promise<{ content: Array<Record<string, unknown>>; warnings: string[] }> => {
  const content: Array<Record<string, unknown>> = [{ type: "text", text: buildSystemPrompt() }];
  const warnings: string[] = [];
  let totalMediaBytes = 0;

  for (const message of messages) {
    const sourceText = message.sourceText.slice(0, 6000);
    if (message.messageType === "text" || !["image", "audio", "video", "document"].includes(message.messageType)) {
      content.push({
        type: "text",
        text: `${labelForEvidence(message)}\n${sourceText || "[empty text]"}`,
      });
      continue;
    }

    if (!message.mediaUrl) {
      const warning = `${message.providerMessageId}: ${message.messageType} evidence has no retrievable media URL; human review required`;
      warnings.push(warning);
      content.push({ type: "text", text: `${labelForEvidence(message, " media_unavailable=true")}\n${sourceText || "[media unavailable]"}` });
      continue;
    }

    const maxBytes = maxBytesForMessageType(message.messageType);
    const media = await downloadMedia(message.mediaUrl, maxBytes);
    assertSupportedMime(message.messageType, media.mime);
    totalMediaBytes += media.bytes.byteLength;
    if (totalMediaBytes > MAX_PACKET_MEDIA_BYTES) throw new Error("PACKET_MEDIA_TOO_LARGE");

    if (message.messageType === "audio") {
      const transcript = await transcribeAudio(apiKey, media);
      content.push({
        type: "text",
        text: `${labelForEvidence(message, " transcript=true")}\n${sourceText ? `CAPTION: ${sourceText}\n` : ""}TRANSCRIPT: ${transcript}`,
      });
      continue;
    }

    content.push({
      type: "text",
      text: `${labelForEvidence(message)}${sourceText ? `\nCAPTION: ${sourceText}` : ""}`,
    });
    const dataUrl = toDataUrl(media.bytes, media.mime);
    if (message.messageType === "image") {
      content.push({ type: "image_url", image_url: { url: dataUrl } });
    } else if (message.messageType === "video") {
      content.push({ type: "video_url", video_url: { url: dataUrl } });
    } else {
      content.push({
        type: "file",
        file: { filename: `whatsapp-po-${message.providerMessageId.slice(-16)}.pdf`, file_data: dataUrl },
      });
    }
  }

  return { content, warnings };
};

const sourceKindForMessages = (messages: LoadedMessage[], packetMode: boolean): SourceKind => {
  if (packetMode || messages.length !== 1) return "packet";
  const kind = messages[0].messageType;
  if (kind === "image" || kind === "audio" || kind === "video" || kind === "document") return kind;
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
    headers: {
      "Content-Type": "application/json",
      "Lovable-API-Key": apiKey,
    },
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
  const first = choices[0] && typeof choices[0] === "object" ? choices[0] as Record<string, unknown> : {};
  const message = first.message && typeof first.message === "object" ? first.message as Record<string, unknown> : {};
  const rawContent = safeString(message.content, 50000);
  if (!rawContent) throw new Error("INTERPRETER_EMPTY_RESPONSE");

  let parsed: unknown;
  try {
    parsed = JSON.parse(rawContent);
  } catch {
    throw new Error("INTERPRETER_INVALID_JSON");
  }
  return sanitizeResult(
    parsed,
    sourceKindForMessages(messages, packetMode),
    prepared.warnings,
    new Set(messages.map((entry) => entry.providerMessageId)),
  );
};

const statusForInterpretationError = (code: string): number => {
  if (code === "INTERPRETER_NOT_CONFIGURED") return 503;
  if (code === "INTERPRETER_PROVIDER_RATE_LIMITED") return 429;
  if (code === "INTERPRETER_PROVIDER_CREDITS_EXHAUSTED") return 503;
  if (code === "INTERPRETER_PROVIDER_AUTH_FAILED") return 502;
  if (code === "INTERPRETER_INVALID_PROVENANCE") return 502;
  if (code === "UNSUPPORTED_IMAGE_TYPE" || code === "UNSUPPORTED_AUDIO_TYPE" || code === "UNSUPPORTED_VIDEO_TYPE" || code === "UNSUPPORTED_DOCUMENT_TYPE") return 415;
  if (code === "EMPTY_MEDIA" || code === "AUDIO_TRANSCRIPTION_EMPTY") return 422;
  if (code === "MEDIA_TOO_LARGE" || code === "PACKET_MEDIA_TOO_LARGE") return 413;
  if (code.startsWith("MEDIA_URL_") || code === "MEDIA_HOST_NOT_ALLOWED" || code === "MEDIA_REDIRECT_NOT_ALLOWED") return 422;
  return 502;
};

const handleRequest = async (req: Request): Promise<Response> => {
  if (req.method === "OPTIONS") return new Response(null, { status: 204, headers: CORS_HEADERS });
  if (req.method !== "POST") return respond({ success: false, error: "METHOD_NOT_ALLOWED" }, 405);

  const authorization = req.headers.get("Authorization");
  if (!authorization?.startsWith("Bearer ")) return respond({ success: false, error: "AUTH_REQUIRED" }, 401);
  const scoped = createScopedClient(authorization);
  if (!scoped) return respond({ success: false, error: "SUPABASE_CONFIG_MISSING" }, 500);

  const { data: authData, error: authError } = await scoped.auth.getUser();
  if (authError || !authData.user) return respond({ success: false, error: "AUTH_INVALID" }, 401);

  const requestIds = await parseRequestIds(req);
  if (!requestIds) return respond({ success: false, error: "PROVIDER_MESSAGE_ID_REQUIRED" }, 400);
  if (requestIds.ids.length > MAX_PACKET_MESSAGES) return respond({ success: false, error: "INTERPRETATION_PACKET_TOO_LARGE" }, 413);

  const loaded = await loadInboundMessages(scoped, requestIds.ids);
  if (loaded.error === "MESSAGE_LOOKUP_FAILED") return respond({ success: false, error: loaded.error }, 500);
  if (!loaded.messages) return respond({ success: false, error: loaded.error ?? "MESSAGE_NOT_FOUND_OR_FORBIDDEN" }, 404);

  const apiKey = Deno.env.get("LOVABLE_API_KEY");
  if (!apiKey) return respond({ success: false, error: "INTERPRETER_NOT_CONFIGURED" }, 503);

  try {
    const interpretation = await callPacketInterpreter(apiKey, loaded.messages, requestIds.packetMode);
    return respond({ success: true, interpretation });
  } catch (error) {
    const code = error instanceof Error ? error.message : "INTERPRETATION_FAILED";
    console.error("[whatsapp-content-interpret]", code.slice(0, 160));
    return respond({ success: false, error: code.slice(0, 160) }, statusForInterpretationError(code));
  }
};

serve(handleRequest);