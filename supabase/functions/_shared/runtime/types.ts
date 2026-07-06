export type ConfidenceBand = "HIGH" | "MEDIUM" | "LOW";
export type ResolverAction = "auto_suggest" | "operator_review" | "ask_clarification";

export type MatchSource =
  | "sku"
  | "name"
  | "short_name"
  | "alias"
  | "canonical_name"
  | "category"
  | "subcategory";

export type RuntimeCatalogProduct = {
  id: string;
  sku: string;
  name: string;
  product_name: string | null;
  short_name: string | null;
  category: string | null;
  subcategory: string | null;
  packaging_code?: string | null;
  is_active?: boolean | null;
  archived_at?: string | null;
  created_at?: string | null;
  updated_at?: string | null;
};

export type RuntimeCatalogAlias = {
  alias_text: string;
  canonical_name: string;
  product_id: string;
  alias_type?: string | null;
};

export type RuntimeCatalog = {
  products: RuntimeCatalogProduct[];
  aliases: RuntimeCatalogAlias[];
};

export type RuntimeCandidate = {
  product_id: string;
  sku: string;
  product_name: string;
  matched_term: string;
  match_source: MatchSource;
  confidence: number;
};

export type RuntimeAlternative = {
  product_id: string;
  sku: string;
  product_name: string;
  confidence: number;
  matched_term: string;
  match_source: MatchSource;
};

export type RuntimeResolverConfig = {
  min_threshold: number;
  high_threshold: number;
  ambiguity_delta: number;
  max_candidates: number;
};

export const DEFAULT_RUNTIME_RESOLVER_CONFIG: RuntimeResolverConfig = {
  min_threshold: 0.72,
  high_threshold: 0.85,
  ambiguity_delta: 0.08,
  max_candidates: 5,
};

export type ProductUtteranceResolution = {
  query: string;
  normalized_text: string;
  resolved_product_id: string | null;
  resolved_sku: string | null;
  resolved_name: string | null;
  confidence: number;
  confidence_band: ConfidenceBand;
  action: ResolverAction;
  reason: string;
  clarification_required: boolean;
  alternatives: RuntimeAlternative[];
  pack_count: number | null;
  order_quantity: number;
};
