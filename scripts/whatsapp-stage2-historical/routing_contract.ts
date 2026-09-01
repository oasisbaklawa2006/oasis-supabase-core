import type { ExpectedBusinessClass } from "./types.ts";

/** Bump when admissible Core outcome sets change. */
export const ROUTING_CONTRACT_VERSION = "wa-stage2-routing/v1";

const C = {
  CLARIFICATION: "CLARIFICATION_REQUIRED",
  HUMAN: "HUMAN_EXCEPTION_REQUIRED",
  POLICY: "POLICY_APPROVAL_REQUIRED",
  FAILED: "FAILED_INTERPRETATION",
  AUTO: "AUTO_ELIGIBLE",
} as const;

export type AdmissibleRoutingContract =
  | { kind: "accounting_only" }
  | { kind: "governed"; outcomes: readonly string[]; forbid_auto: boolean };

/** Explicit admissible Core outcomes per ExpectedBusinessClass (WhatsApp governance). */
export const ADMISSIBLE_ROUTING: Record<
  ExpectedBusinessClass,
  AdmissibleRoutingContract
> = {
  ORDER: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN, C.POLICY],
    forbid_auto: true,
  },
  ORDER_AMENDMENT: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN, C.POLICY],
    forbid_auto: true,
  },
  ORDER_CANCELLATION: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  PAYMENT_PROOF: {
    kind: "governed",
    outcomes: [C.HUMAN, C.POLICY, C.CLARIFICATION],
    forbid_auto: true,
  },
  PAYMENT_QUERY: {
    kind: "governed",
    outcomes: [C.HUMAN, C.POLICY, C.CLARIFICATION],
    forbid_auto: true,
  },
  COMPLAINT: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION],
    forbid_auto: true,
  },
  SHORTAGE: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION],
    forbid_auto: true,
  },
  WRONG_QUANTITY: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION],
    forbid_auto: true,
  },
  DISPATCH_REQUEST: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  DISPATCH_STATUS: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION],
    forbid_auto: true,
  },
  SO_REQUEST: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  SO_REFERENCE: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION],
    forbid_auto: true,
  },
  DELIVERY_ADDRESS: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  TRANSPORTER: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  SAMPLE_REQUEST: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  PI_REQUEST: {
    kind: "governed",
    outcomes: [C.HUMAN, C.POLICY, C.CLARIFICATION],
    forbid_auto: true,
  },
  INVOICE_LEDGER: {
    kind: "governed",
    outcomes: [C.HUMAN, C.POLICY, C.CLARIFICATION],
    forbid_auto: true,
  },
  CUSTOMISATION: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN],
    forbid_auto: true,
  },
  INTERNAL_OPERATION: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION],
    forbid_auto: true,
  },
  NON_ORDER_BUSINESS: {
    kind: "governed",
    outcomes: [C.HUMAN, C.CLARIFICATION, C.FAILED],
    forbid_auto: true,
  },
  AMBIGUOUS_REQUIRES_HUMAN: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.HUMAN, C.FAILED],
    forbid_auto: true,
  },
  MEDIA_UNAVAILABLE: {
    kind: "governed",
    outcomes: [C.CLARIFICATION, C.FAILED, C.HUMAN],
    forbid_auto: true,
  },
  DELETED_MESSAGE: { kind: "accounting_only" },
  SYSTEM_EXCLUDED: { kind: "accounting_only" },
};

export function listExpectedBusinessClasses(): ExpectedBusinessClass[] {
  return Object.keys(ADMISSIBLE_ROUTING) as ExpectedBusinessClass[];
}

export function routingMatchesExpectation(
  expected: ExpectedBusinessClass,
  observedCoreOutcome: string | null,
  autoActioned: boolean,
): boolean {
  const contract = ADMISSIBLE_ROUTING[expected];
  if (!contract) return false;

  if (contract.kind === "accounting_only") {
    return !autoActioned;
  }

  if (contract.forbid_auto && autoActioned) return false;
  if (!observedCoreOutcome) return false;
  if (observedCoreOutcome === C.AUTO && contract.forbid_auto) return false;

  return contract.outcomes.includes(observedCoreOutcome);
}
