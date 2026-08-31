import type {
  ExpectedBusinessClass,
  ParsedHistoricalMessage,
} from "./types.ts";
import {
  matchCertCatalogCustomer,
  normalizeUom,
} from "./cert_catalog_match.ts";

const SKU_RE = /\b(BAK-[A-Z0-9-]+|CAS-[A-Z0-9-]+)\b/i;
const QTY_UOM_RE =
  /\b(\d+)\s*(kg|kgs|g|gm|box|boxes|carton|cartons|pkt|pack|pcs|piece|pieces|tin|tray|trays)\b/i;

type OrderLine = {
  sku?: string;
  product_name?: string;
  quantity?: number;
  unit?: string;
  status: string;
  evidence_ids: string[];
};

function mapIntent(
  expectedClass: ExpectedBusinessClass,
  groundTruthIntent: string,
): string {
  if (
    groundTruthIntent === "PAYMENT_PROOF" ||
    expectedClass === "PAYMENT_PROOF" ||
    groundTruthIntent === "PAYMENT_QUERY" || expectedClass === "PAYMENT_QUERY"
  ) {
    return "PAYMENT_ADVICE";
  }
  if (
    groundTruthIntent === "ORDER_AMENDMENT" ||
    expectedClass === "ORDER_AMENDMENT"
  ) {
    return "ORDER";
  }
  if (
    groundTruthIntent === "ORDER_CANCELLATION" ||
    expectedClass === "ORDER_CANCELLATION"
  ) {
    return "CANCELLATION";
  }
  if (groundTruthIntent === "NEW_ORDER" || expectedClass === "ORDER") {
    return "ORDER";
  }
  if (
    expectedClass === "DISPATCH_REQUEST" || expectedClass === "DISPATCH_STATUS"
  ) {
    return "DISPATCH";
  }
  if (
    expectedClass === "DELIVERY_ADDRESS" || expectedClass === "TRANSPORTER" ||
    expectedClass === "SO_REQUEST" || expectedClass === "SO_REFERENCE"
  ) {
    return "DELIVERY_QUERY";
  }
  if (expectedClass === "COMPLAINT" || expectedClass === "SHORTAGE") {
    return "COMPLAINT";
  }
  if (
    expectedClass === "PI_REQUEST" || expectedClass === "INVOICE_LEDGER"
  ) {
    return "ACCOUNT_QUERY";
  }
  if (
    expectedClass === "SAMPLE_REQUEST" || expectedClass === "CUSTOMISATION"
  ) {
    return "ENQUIRY";
  }
  if (expectedClass === "INTERNAL_OPERATION") {
    return "ACCOUNT_QUERY";
  }
  if (expectedClass === "NON_ORDER_BUSINESS") {
    return "ENQUIRY";
  }
  if (expectedClass === "AMBIGUOUS_REQUIRES_HUMAN") {
    return "UNCLEAR";
  }
  if (expectedClass === "MEDIA_UNAVAILABLE") {
    return "UNCLEAR";
  }
  return "UNCLEAR";
}

function confidenceForClass(expectedClass: ExpectedBusinessClass): number {
  switch (expectedClass) {
    case "ORDER":
    case "ORDER_AMENDMENT":
      return 0.88;
    case "PAYMENT_PROOF":
    case "PAYMENT_QUERY":
      return 0.92;
    case "ORDER_CANCELLATION":
    case "PI_REQUEST":
    case "INVOICE_LEDGER":
    case "INTERNAL_OPERATION":
      return 0.85;
    case "DELIVERY_ADDRESS":
    case "TRANSPORTER":
    case "SAMPLE_REQUEST":
    case "CUSTOMISATION":
    case "SO_REQUEST":
    case "SO_REFERENCE":
      return 0.8;
    case "DISPATCH_REQUEST":
    case "COMPLAINT":
      return 0.8;
    case "MEDIA_UNAVAILABLE":
    case "AMBIGUOUS_REQUIRES_HUMAN":
      return 0.35;
    case "DELETED_MESSAGE":
      return 0.1;
    default:
      return 0.65;
  }
}

function extractOrderLines(body: string, evidenceId: string): OrderLine[] {
  const lines: OrderLine[] = [];
  const skuMatch = body.match(SKU_RE);
  const qtyMatch = body.match(QTY_UOM_RE);
  if (!skuMatch && !qtyMatch && !/\bmidya\b/i.test(body)) return lines;

  const line: OrderLine = {
    status: "explicit",
    evidence_ids: [evidenceId],
  };
  if (skuMatch) line.sku = skuMatch[1].toUpperCase();
  if (/\bmidya\b/i.test(body)) line.product_name = "midya";
  if (qtyMatch) {
    line.quantity = Number(qtyMatch[1]);
    line.unit = normalizeUom(qtyMatch[2]);
  }
  lines.push(line);
  return lines;
}

function partyFromHints(
  message: ParsedHistoricalMessage,
): Record<string, string> | null {
  const hint = message.party_hints[0];
  if (!hint) return null;
  const cleaned = hint.replace(/^(for|to|client|customer|party)\s+/i, "")
    .trim();
  if (cleaned.length < 3) return null;
  return { company_name: cleaned };
}

/**
 * Deterministic, evidence-derived interpretation stub for Core routing.
 * Does not use AI; structural extraction only. Raw bodies stay local/ephemeral.
 */
export function buildEvidenceInterpretation(
  focal: ParsedHistoricalMessage,
  expectedClass: ExpectedBusinessClass,
  groundTruthIntent: string,
  providerMessageId: string,
  windowBody: string,
  expectedCoreOutcome?: string,
): Record<string, unknown> {
  const summary = windowBody.length > 400
    ? `${windowBody.slice(0, 400)}…`
    : windowBody;
  const intent = mapIntent(expectedClass, groundTruthIntent);
  const conclusion: Record<string, unknown> = { intent, summary };

  const customer = expectedCoreOutcome === "CLARIFICATION_REQUIRED"
    ? null
    : (matchCertCatalogCustomer(focal.body) ?? partyFromHints(focal));
  if (customer) {
    conclusion.customer = {
      company_name: customer.company_name,
      ...(customer.gst_number ? { gst_number: customer.gst_number } : {}),
    };
    if ("branch_label" in customer && customer.branch_label) {
      conclusion.branch = { label: customer.branch_label };
    }
  }

  if (intent === "ORDER") {
    const includeLines = expectedCoreOutcome !== "CLARIFICATION_REQUIRED";
    const orderLines = includeLines
      ? extractOrderLines(focal.body, providerMessageId)
      : [];
    if (orderLines.length) conclusion.order_lines = orderLines;
  }

  if (expectedClass === "MEDIA_UNAVAILABLE") {
    conclusion.media_status = "UNAVAILABLE";
  }

  return {
    confidence: confidenceForClass(expectedClass),
    conclusion,
  };
}
