/** @file Deterministic CERT master catalog — NON-PRODUCTION Stage-1B only. */

const NS = "b1000000-0000-0000-0000";

function certId(suffix: number): string {
  return `${NS}-${String(suffix).padStart(12, "0")}`;
}

export const CERT_ADMIN_USER = {
  id: certId(1),
  email: "cert-a-admin@example.test",
};

export const CERT_KNOWLEDGE = {
  snapshot_id: certId(10),
  checksum: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  knowledge: {
    schema_version: "wa-knowledge/v1",
    terminology: { midya: "Special Assorted Mix" },
    aliases: {},
    sku_map: {},
    packaging: {},
    ambiguous_terms: [],
    source_catalogue_version_ids: [],
  },
};

export const CERT_PRODUCTS = [
  {
    id: certId(101),
    sku: "BAK-PIST-250",
    name: "Pistachio Baklawa 250g",
    selling_price: 500,
    moq: 5,
    pricing_rule_id: certId(161),
    moq_rule_id: certId(171),
  },
  {
    id: certId(104),
    sku: "MIX-ASST-500",
    name: "Special Assorted Mix",
    selling_price: 750,
    moq: 1,
    pricing_rule_id: certId(164),
    moq_rule_id: certId(174),
  },
];

export const CERT_CUSTOMERS = [
  {
    id: certId(201),
    business_name: "Taj Sweets Bengaluru",
    gst_number: "29ABCDE1234F1Z5",
    company_phone: "919800000001",
    payment_terms: "credit",
    is_frozen: false,
    branch_id: certId(211),
    branch_label: "Main Store",
  },
];

export const CERT_EMPLOYEES = [
  {
    id: certId(301),
    phone: "919900000001",
    name: "Sales Executive Priya",
  },
];
