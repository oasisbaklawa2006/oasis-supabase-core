import type { ParsedHistoricalMessage } from "../whatsapp-stage2-historical/types.ts";
import type { ImageSubtype, MediaModality } from "./types.ts";

const SKU_RE = /\b(BAK-[A-Z0-9-]+|CAS-[A-Z0-9-]+)\b/i;
const QTY_UOM_RE =
  /\b(\d+(?:\.\d+)?)\s*(kg|kgs|g|gm|box|boxes|carton|cartons|pkt|pack|pcs|piece|pieces|tin|tray|trays)\b/i;

export function modalityFromEntry(entryName: string, message: ParsedHistoricalMessage): MediaModality {
  const lower = entryName.toLowerCase();
  if (/\.(jpg|jpeg|png|webp|gif)$/.test(lower) || message.media_type === "image") {
    return "IMAGE";
  }
  if (/\.(mp4|mov)$/.test(lower) || message.media_type === "video") return "VIDEO";
  if (/\.(opus|ogg|mp3|m4a)$/.test(lower) || message.media_type === "audio") {
    return "AUDIO";
  }
  if (/\.(pdf|doc|docx|pptx|xlsx)$/.test(lower) || message.media_type === "document") {
    return "PDF";
  }
  return "OTHER";
}

export function classifyImageSubtype(
  message: ParsedHistoricalMessage,
  contextMessages: ParsedHistoricalMessage[],
): ImageSubtype {
  const body = message.body.toLowerCase();
  const allBodies = [message, ...contextMessages].map((m) => m.body.toLowerCase()).join("\n");

  if (/\b(payment|utr|upi|neft|imps|paid)\b/.test(allBodies)) {
    return "PAYMENT_PROOF";
  }
  if (/\b(damaged|broken|shortage|complaint|wrong)\b/.test(allBodies)) {
    return "COMPLAINT_DAMAGE";
  }
  if (/\b(po\b|purchase order|p\.o\.)\b/.test(allBodies)) {
    return "PURCHASE_ORDER_IMAGE";
  }
  if (/\b(catalogue|catalog|menu|rate list|price list)\b/.test(allBodies)) {
    return "CATALOGUE_SCREENSHOT";
  }
  if (message.is_forwarded || /\bforwarded message\b/i.test(message.body)) {
    return "FORWARDED_SCREENSHOT";
  }
  if (/\b(handwritten|hand writing|written order)\b/.test(allBodies)) {
    return "HANDWRITTEN_ORDER";
  }
  if (SKU_RE.test(allBodies) || /\b(label|barcode|sku)\b/.test(allBodies)) {
    return "PRODUCT_LABEL_VISIBLE";
  }
  if (/\bscreenshot\b/.test(allBodies) || /screen\s?shot/i.test(allBodies)) {
    return "SCREENSHOT";
  }
  if (
    contextMessages.some((m) =>
      /\b(revised|correction|make it|add more|reduce to|cancel)\b/i.test(m.body)
    )
  ) {
    return "MEDIA_WITH_CORRECTION";
  }
  if (contextMessages.filter((m) => m.media_type === "image").length > 1) {
    return "MULTI_IMAGE";
  }
  if (/\b(product|baklawa|sweet|midya)\b/.test(allBodies) && !ORDER_LINE(allBodies)) {
    return "PRODUCT_PHOTO";
  }
  if (body.trim() === "" || /^(image|photo)\s+omitted$/i.test(body.trim())) {
    return "IMAGE_ONLY";
  }
  if (body.length > 0 && !/omitted$/i.test(body)) {
    return "IMAGE_WITH_CAPTION";
  }
  if (message.media_type === "image" && body.length < 8) {
    return "IMAGE_ONLY";
  }
  return "AMBIGUOUS_OR_LOW_QUALITY";
}

function ORDER_LINE(body: string): boolean {
  return QTY_UOM_RE.test(body) || SKU_RE.test(body) ||
    /\b(order|send|dispatch|qty|quantity)\b/.test(body);
}

export function countByModality(
  pairs: Array<{ modality: MediaModality }>,
): Record<MediaModality, number> {
  const counts: Record<MediaModality, number> = {
    IMAGE: 0,
    PDF: 0,
    AUDIO: 0,
    VIDEO: 0,
    OTHER: 0,
  };
  for (const pair of pairs) counts[pair.modality] += 1;
  return counts;
}

export function countImageSubtypes(
  pairs: Array<{ image_subtype: ImageSubtype | null }>,
): Record<string, number> {
  const counts: Record<string, number> = {};
  for (const pair of pairs) {
    if (!pair.image_subtype) continue;
    counts[pair.image_subtype] = (counts[pair.image_subtype] ?? 0) + 1;
  }
  return counts;
}
