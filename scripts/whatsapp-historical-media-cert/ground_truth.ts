import { inferExpectation } from "../whatsapp-stage2-historical/expectations.ts";
import type { CertificationWindow, ParsedHistoricalMessage } from "../whatsapp-stage2-historical/types.ts";
import { sha256Hex } from "../whatsapp-stage2-historical/parse_export.ts";
import { buildCertificationWindows } from "../whatsapp-stage2-historical/segment.ts";
import {
  classifyImageSubtype,
  modalityFromEntry,
} from "./media_inventory.ts";
import {
  buildDetailedMediaPairing,
  listZipEntries,
} from "./media_pairing.ts";
import type {
  GroundTruthField,
  HistoricalMediaGroundTruth,
  PairedMediaReference,
} from "./types.ts";

const SKU_RE = /\b(BAK-[A-Z0-9-]+|CAS-[A-Z0-9-]+)\b/i;
const QTY_UOM_RE =
  /\b(\d+(?:\.\d+)?)\s*(kg|kgs|g|gm|box|boxes|carton|cartons|pkt|pack|pcs|piece|pieces|tin|tray|trays)\b/i;

function explicitSku(messages: ParsedHistoricalMessage[]): GroundTruthField {
  for (const message of messages) {
    const match = message.body.match(SKU_RE);
    if (match) return match[1].toUpperCase();
  }
  return "UNKNOWN";
}

function explicitQuantity(messages: ParsedHistoricalMessage[]): GroundTruthField {
  for (const message of messages) {
    const match = message.body.match(QTY_UOM_RE);
    if (match) return Number(match[1]);
  }
  return "UNKNOWN";
}

function explicitUom(messages: ParsedHistoricalMessage[]): GroundTruthField {
  for (const message of messages) {
    const match = message.body.match(QTY_UOM_RE);
    if (match) return match[2].toLowerCase();
  }
  return "UNKNOWN";
}

function provableCustomer(
  focal: ParsedHistoricalMessage,
  context: ParsedHistoricalMessage[],
): GroundTruthField {
  const hints = [...focal.party_hints];
  for (const message of context) hints.push(...message.party_hints);
  const unique = [...new Set(hints.map((h) => h.trim()).filter(Boolean))];
  if (unique.length === 1) return unique[0];
  return "UNKNOWN";
}

function buildGroundTruth(
  focal: ParsedHistoricalMessage,
  context: ParsedHistoricalMessage[],
  expectation: ReturnType<typeof inferExpectation>,
): HistoricalMediaGroundTruth {
  const all = [focal, ...context];
  const sku = explicitSku(all);
  const quantity = explicitQuantity(all);
  const uom = explicitUom(all);
  const customer = provableCustomer(focal, context);
  const clarificationRequired = expectation.expected_core_outcome ===
    "CLARIFICATION_REQUIRED";
  const humanExceptionRequired = expectation.expected_core_outcome ===
    "HUMAN_EXCEPTION_REQUIRED";
  const autonomousSafe = !clarificationRequired && !humanExceptionRequired &&
    sku !== "UNKNOWN" && quantity !== "UNKNOWN" && uom !== "UNKNOWN" &&
    customer !== "UNKNOWN" && expectation.should_auto_action;

  return {
    intent: expectation.ground_truth_intent,
    customer,
    branch: "UNKNOWN",
    product_family: sku !== "UNKNOWN" ? sku.split("-").slice(0, 2).join("-") : "UNKNOWN",
    exact_sku: sku,
    quantity,
    uom,
    pack: "UNKNOWN",
    autonomous_safe: autonomousSafe ? true : "UNKNOWN",
    clarification_required: clarificationRequired,
    human_exception_required: humanExceptionRequired,
    expected_core_outcome: expectation.expected_core_outcome,
    expected_class: expectation.expected_class,
  };
}

function eligibility(
  pair: { archive_entry: string | null },
  groundTruth: HistoricalMediaGroundTruth,
): { eligible: boolean; reason: string | null } {
  if (!pair.archive_entry) {
    return { eligible: false, reason: "UNPAIRED_ARCHIVE_ENTRY" };
  }
  if (groundTruth.expected_class === "DELETED_MESSAGE") {
    return { eligible: false, reason: "DELETED_MESSAGE" };
  }
  return { eligible: true, reason: null };
}

function stratumFor(
  modality: string,
  imageSubtype: string | null,
  groundTruth: HistoricalMediaGroundTruth,
): string {
  if (imageSubtype) return `IMAGE:${imageSubtype}`;
  if (groundTruth.expected_class === "ORDER") return `${modality}:ORDER`;
  if (groundTruth.expected_class === "PAYMENT_PROOF") return `${modality}:PAYMENT_PROOF`;
  if (groundTruth.expected_class === "COMPLAINT") return `${modality}:COMPLAINT`;
  return `${modality}:${groundTruth.expected_class}`;
}

export async function buildPairedMediaPopulation(
  mediaZipPath: string,
  messages: ParsedHistoricalMessage[],
): Promise<PairedMediaReference[]> {
  const zipEntries = await listZipEntries(mediaZipPath);
  const mediaBearing = messages.filter((m) => m.media_type != null);
  const detailed = buildDetailedMediaPairing(mediaBearing, zipEntries);
  const windows = buildCertificationWindows(messages);
  const windowByFocal = new Map(windows.map((w) => [w.focal_index, w]));
  const byIndex = new Map(messages.map((m) => [m.index, m]));
  const population: PairedMediaReference[] = [];

  for (const pair of detailed) {
    const focal = pair.message;
    const window = windowByFocal.get(focal.index) ?? null;
    const contextIndices = window?.message_indices.filter((i) => i !== focal.index) ?? [];
    const contextMessages = contextIndices
      .map((i) => byIndex.get(i))
      .filter(Boolean) as ParsedHistoricalMessage[];
    const expectation = inferExpectation(focal, messages, window?.message_indices ?? [focal.index]);
    const groundTruth = buildGroundTruth(focal, contextMessages, expectation);
    const modality = pair.archive_entry
      ? modalityFromEntry(pair.archive_entry, focal)
      : modalityFromEntry("", focal);
    const imageSubtype = modality === "IMAGE"
      ? classifyImageSubtype(focal, contextMessages)
      : null;
    const { eligible, reason } = eligibility(pair, groundTruth);
    const caseId = (await sha256Hex(
      `hist-media:${focal.index}:${pair.archive_entry ?? "unpaired"}`,
    )).slice(0, 16);

    population.push({
      case_id: caseId,
      message_index: focal.index,
      archive_entry: pair.archive_entry ?? "",
      modality,
      image_subtype: imageSubtype,
      focal,
      window,
      context_messages: contextMessages,
      expectation,
      ground_truth: groundTruth,
      eligible,
      ineligible_reason: reason,
      stratum: stratumFor(modality, imageSubtype, groundTruth),
    });
  }

  return population;
}
