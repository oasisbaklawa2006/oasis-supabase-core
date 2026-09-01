import { ROUTING_CONTRACT_VERSION } from "./routing_contract.ts";

/** Reproducible PASS semantics persisted in certification artifacts. */
export const STAGE2_PASS_VERDICT_CONTRACT = {
  gate_summary:
    "Stage-2 PASS is gated by aggregate governed routing benchmark, zero-tolerance counters, reconciliation balance, execution coverage, and sanitized violations — not by exact Core outcome equality.",
  outcome_mismatches_role:
    "dangerous_failure_counters.outcome_mismatches counts windows where observed_core_outcome differs from expected_core_outcome (exact Core-outcome difference). Informational only; excluded from the PASS verdict gate.",
  admissible_routing_gate:
    `PASS evaluates routingMatchesExpectation() against ${ROUTING_CONTRACT_VERSION} ADMISSIBLE_ROUTING per ExpectedBusinessClass, permitting any admissible governed outcome rather than requiring exact outcome string match.`,
} as const;

export const STAGE2_FIELD_ACCURACY_LABELS = {
  clarification_rate:
    "Informational rate of CLARIFICATION_REQUIRED outcomes — not outcome accuracy.",
} as const;

export const STAGE2_COUNTER_SEMANTICS = {
  outcome_mismatches:
    "Exact Core-outcome differences (observed_core_outcome !== expected_core_outcome). Excluded from PASS gate; Stage-2 PASS uses admissible routing contract match instead.",
} as const;
