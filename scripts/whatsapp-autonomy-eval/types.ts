export type GroundTruth = {
  intent: string;
  customer: string | null;
  branch: string | null;
  sku: string | null;
  quantity: number | null;
  uom: string | null;
  confirmed_so: boolean;
};

export type SanitizedCaseInput = {
  submitter_phone: string;
  submitter_name: string;
  provider_message_id: string;
  message_body: string;
  message_type?: string;
  interpretation: Record<string, unknown>;
};

export type GoldenCase = {
  id: string;
  traffic_class: string;
  input: SanitizedCaseInput;
  ground_truth: GroundTruth;
  expected_core_outcome: string;
  should_auto_action: boolean;
  replay_twice?: boolean;
};

export type ObservedResult = {
  case_id: string;
  observed_core_outcome: string | null;
  observed_auto_actioned: boolean;
  observed_customer: string | null;
  observed_branch: string | null;
  observed_sku: string | null;
  observed_quantity: number | null;
  observed_uom: string | null;
  potential_order_state: string | null;
  potential_order_disposition: string | null;
  draft_id: string | null;
  promoted_order_id: string | null;
  selling_price: number | null;
  payment_terms: string | null;
  invented_commercial_leaked: boolean;
  idempotent_replay: boolean;
  error: string | null;
};

export type EvalPair = {
  golden: GoldenCase;
  observed: ObservedResult;
};

export type EvalReport = {
  total: number;
  traffic_class_distribution: Record<string, number>;
  auto_actioned: number;
  straight_through_rate: number;
  clarification_rate: number;
  policy_or_human_exception_rate: number;
  failed_interpretation_rate: number;
  dangerous_false_positives: string[];
  dangerous_false_positive_rate: number;
  false_orders: string[];
  outcome_mismatches: string[];
  customer_accuracy: number;
  branch_accuracy: number;
  sku_accuracy: number;
  quantity_accuracy: number;
  uom_accuracy: number;
  blocked: boolean;
  violations: string[];
};
