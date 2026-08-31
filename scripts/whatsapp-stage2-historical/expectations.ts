import type {
  ExpectedBusinessClass,
  ParsedHistoricalMessage,
} from "./types.ts";

export type ExpectationResult = {
  expected_class: ExpectedBusinessClass;
  expected_core_outcome: string;
  should_auto_action: boolean;
  traffic_class: string;
  linkage_reasons: string[];
  ground_truth_intent: string;
};

const ORDER_LINE_RE =
  /\b(\d+\s*(kg|kgs|g|gm|box|boxes|carton|cartons|pkt|pack|pcs|piece|pieces|tin|tray|trays)?|bak-|cas-|sku)\b/i;

function bodyLower(message: ParsedHistoricalMessage): string {
  return message.body.toLowerCase();
}

function hasMediaUnavailable(message: ParsedHistoricalMessage): boolean {
  return /(image omitted|video omitted|audio omitted|document omitted|media omitted)/i
    .test(message.body);
}

function essentialMediaDependency(body: string): boolean {
  return /\b(so\??|screenshot|payment|invoice|pi\b|ledger|photo|image|pdf|document)\b/i
    .test(body);
}

export function inferExpectation(
  focal: ParsedHistoricalMessage,
  allMessages: ParsedHistoricalMessage[],
  contextIndices: number[],
): ExpectationResult {
  const linkage_reasons: string[] = [];
  const body = bodyLower(focal);

  if (focal.is_deleted) {
    return pack("DELETED_MESSAGE", "HUMAN_EXCEPTION_REQUIRED", false, "deleted_message", "DELETED", linkage_reasons);
  }

  if (hasMediaUnavailable(focal) && essentialMediaDependency(body)) {
    linkage_reasons.push("media_placeholder_essential");
    return pack("MEDIA_UNAVAILABLE", "CLARIFICATION_REQUIRED", false, "media_unavailable", "MEDIA_UNAVAILABLE", linkage_reasons);
  }

  if (/\border cancel|cancel order|cancelled order|cancel the order\b/.test(body)) {
    linkage_reasons.push("cancellation_language");
    return pack("ORDER_CANCELLATION", "CLARIFICATION_REQUIRED", false, "order_cancellation", "ORDER_CANCELLATION", linkage_reasons);
  }

  if (/\b(please add|add more|add another|qty increase|make it|revised order|revised qty|revision|increase to|reduce to)\b/.test(body)) {
    linkage_reasons.push("amendment_language");
    return pack("ORDER_AMENDMENT", "CLARIFICATION_REQUIRED", false, "order_amendment", "ORDER_AMENDMENT", linkage_reasons);
  }

  if (/\b(utr|upi|payment received|paid|neft|imps|rtgs|payment screenshot|payment done)\b/.test(body) ||
    (focal.media_type === "image" && /\b(pay|paid|rs\.?|inr|amount|invoice)\b/.test(body))) {
    return pack("PAYMENT_PROOF", "HUMAN_EXCEPTION_REQUIRED", false, "payment_proof", "PAYMENT_PROOF", linkage_reasons);
  }

  if (/\b(payment status|payment query|payment pending|when paid)\b/.test(body)) {
    return pack("PAYMENT_QUERY", "HUMAN_EXCEPTION_REQUIRED", false, "payment_query", "PAYMENT_QUERY", linkage_reasons);
  }

  if (/\b(dispatch today|dispatch tomorrow|urgent dispatch|asap dispatch|dispatch asap|dispatch now|balance goods|client waiting|dod|delivery today|deliver today)\b/.test(body)) {
    linkage_reasons.push("dispatch_language");
    return pack("DISPATCH_REQUEST", "CLARIFICATION_REQUIRED", false, "dispatch_request", "DISPATCH_REQUEST", linkage_reasons);
  }

  if (/\b(dispatched|out for delivery|delivered|in transit|lr number|transport)\b/.test(body)) {
    return pack("DISPATCH_STATUS", "HUMAN_EXCEPTION_REQUIRED", false, "dispatch_status", "DISPATCH_STATUS", linkage_reasons);
  }

  if (/\b(short received|shortage|missing item|extra quantity|wrong material|wrong qty|complaint|damaged|broken|decorated stock)\b/.test(body)) {
    return pack("COMPLAINT", "HUMAN_EXCEPTION_REQUIRED", false, "complaint_shortage", "COMPLAINT", linkage_reasons);
  }

  if (/\bso[\s#:-]*\d{4,8}\b/.test(body) && /\?\s*$/.test(body.trim())) {
    return pack("SO_REQUEST", "CLARIFICATION_REQUIRED", false, "so_request", "SO_REQUEST", linkage_reasons);
  }

  if (focal.so_references.length >= 1 && !ORDER_LINE_RE.test(body)) {
    linkage_reasons.push("so_reference_only");
    return pack("SO_REFERENCE", "HUMAN_EXCEPTION_REQUIRED", false, "so_reference", "SO_REFERENCE", linkage_reasons);
  }

  if (/\b(address|location|pincode|pin code|deliver to|ship to|transporter|vehicle|lr\b|truck)\b/.test(body)) {
    const cls = /\btransporter|vehicle|lr\b|truck\b/.test(body) ? "TRANSPORTER" : "DELIVERY_ADDRESS";
    return pack(cls, "CLARIFICATION_REQUIRED", false, cls.toLowerCase(), cls, linkage_reasons);
  }

  if (/\b(sample|tasting|trial pack|test batch)\b/.test(body)) {
    return pack("SAMPLE_REQUEST", "CLARIFICATION_REQUIRED", false, "sample_request", "SAMPLE_REQUEST", linkage_reasons);
  }

  if (/\b(pi\b|proforma|pro-forma|invoice copy|ledger|statement)\b/.test(body)) {
    const cls = /\bpi\b|proforma|pro-forma/.test(body) ? "PI_REQUEST" : "INVOICE_LEDGER";
    return pack(cls, "HUMAN_EXCEPTION_REQUIRED", false, cls.toLowerCase(), cls, linkage_reasons);
  }

  if (/\b(custom|customization|special packing|label|print)\b/.test(body)) {
    return pack("CUSTOMISATION", "CLARIFICATION_REQUIRED", false, "customisation", "CUSTOMISATION", linkage_reasons);
  }

  if (ORDER_LINE_RE.test(body) || /\b(order|send|dispatch|moq|midya|baklawa|kg|box)\b/.test(body)) {
    const contextBodies = contextIndices
      .map((idx) => allMessages.find((m) => m.index === idx))
      .filter(Boolean) as ParsedHistoricalMessage[];
    const hasAdjacentParty = contextBodies.some((m) => m.party_hints.length > 0);
    if (hasAdjacentParty) linkage_reasons.push("adjacent_party_context");
    if (focal.is_forwarded) linkage_reasons.push("forwarded_instruction");
    return pack("ORDER", "CLARIFICATION_REQUIRED", false, "employee_mediated_order", "NEW_ORDER", linkage_reasons);
  }

  if (/\b(hod|team|shift|production|factory|internal|confirm internally|ops)\b/.test(body)) {
    return pack("INTERNAL_OPERATION", "HUMAN_EXCEPTION_REQUIRED", false, "internal_operation", "INTERNAL_OPERATION", linkage_reasons);
  }

  if (/\b(maybe|not sure|which one|which order|which customer|confirm\??)\b/.test(body)) {
    return pack("AMBIGUOUS_REQUIRES_HUMAN", "CLARIFICATION_REQUIRED", false, "ambiguous_requires_human", "AMBIGUOUS", linkage_reasons);
  }

  return pack("NON_ORDER_BUSINESS", "HUMAN_EXCEPTION_REQUIRED", false, "non_order_business", "GENERAL", linkage_reasons);
}

function pack(
  expected_class: ExpectedBusinessClass,
  expected_core_outcome: string,
  should_auto_action: boolean,
  traffic_class: string,
  ground_truth_intent: string,
  linkage_reasons: string[],
): ExpectationResult {
  return {
    expected_class,
    expected_core_outcome,
    should_auto_action,
    traffic_class,
    linkage_reasons,
    ground_truth_intent,
  };
}

export function mapObservedRoutingClass(
  observedCoreOutcome: string | null,
  autoActioned: boolean,
): ExpectedBusinessClass | "UNROUTED" {
  if (!observedCoreOutcome) return "UNROUTED";
  if (autoActioned) return "ORDER";
  switch (observedCoreOutcome) {
    case "POLICY_APPROVAL_REQUIRED":
      return "PAYMENT_PROOF";
    case "CLARIFICATION_REQUIRED":
      return "AMBIGUOUS_REQUIRES_HUMAN";
    case "HUMAN_EXCEPTION_REQUIRED":
      return "NON_ORDER_BUSINESS";
    case "FAILED_INTERPRETATION":
      return "MEDIA_UNAVAILABLE";
    default:
      return "NON_ORDER_BUSINESS";
  }
}

export function routingMatchesExpectation(
  expected: ExpectedBusinessClass,
  observedCoreOutcome: string | null,
  autoActioned: boolean,
): boolean {
  if (expected === "DELETED_MESSAGE" || expected === "SYSTEM_EXCLUDED") return true;
  if (expected === "ORDER" || expected === "ORDER_AMENDMENT") {
    if (autoActioned) return false;
    return observedCoreOutcome === "CLARIFICATION_REQUIRED" ||
      observedCoreOutcome === "HUMAN_EXCEPTION_REQUIRED" ||
      observedCoreOutcome === "POLICY_APPROVAL_REQUIRED";
  }
  if (expected === "ORDER_CANCELLATION") {
    return !autoActioned && observedCoreOutcome !== "AUTO_ELIGIBLE";
  }
  if (expected === "PAYMENT_PROOF" || expected === "PAYMENT_QUERY") {
    return (observedCoreOutcome === "POLICY_APPROVAL_REQUIRED" ||
      observedCoreOutcome === "HUMAN_EXCEPTION_REQUIRED" ||
      observedCoreOutcome === "CLARIFICATION_REQUIRED") && !autoActioned;
  }
  if (expected === "COMPLAINT" || expected === "SHORTAGE" || expected === "WRONG_QUANTITY") {
    return !autoActioned && observedCoreOutcome !== "AUTO_ELIGIBLE";
  }
  if (expected === "DISPATCH_REQUEST" || expected === "DISPATCH_STATUS") {
    return !autoActioned;
  }
  if (expected === "SO_REFERENCE" || expected === "SO_REQUEST") {
    return !autoActioned;
  }
  if (expected === "MEDIA_UNAVAILABLE") {
    return observedCoreOutcome === "CLARIFICATION_REQUIRED" ||
      observedCoreOutcome === "FAILED_INTERPRETATION" ||
      observedCoreOutcome === "HUMAN_EXCEPTION_REQUIRED";
  }
  if (expected === "NON_ORDER_BUSINESS" || expected === "INTERNAL_OPERATION") {
    return !autoActioned;
  }
  return observedCoreOutcome === expected || !autoActioned;
}
