export type BranchRef = {
  id: string;
  label: string;
};

export type CustomerRef = {
  id: string;
  ref: string;
  business_name: string;
  gst_number: string;
  company_phone: string;
  payment_terms: string;
  is_frozen: boolean;
  branches: Record<string, BranchRef>;
};

export type ProductRef = {
  id: string;
  ref: string;
  sku: string;
  name: string;
  selling_price: number;
  moq: number;
  pricing_rule_id: string;
  moq_rule_id: string;
};

export const CERT_NAMESPACE = "b1000000-0000-0000-0000";

function certId(suffix: number): string {
  return `${CERT_NAMESPACE}-${String(suffix).padStart(12, "0")}`;
}

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

export const CERT_ADMIN_USER = {
  id: certId(1),
  email: "cert-a-admin@example.test",
};

export const CERT_EMPLOYEES: Record<
  string,
  { id: string; phone: string; name: string }
> = {
  "EMP-001": {
    id: certId(301),
    phone: "919900000001",
    name: "Sales Executive Priya",
  },
  "EMP-002": {
    id: certId(302),
    phone: "919900000002",
    name: "Sales Executive Arjun",
  },
  "EMP-003": {
    id: certId(303),
    phone: "919900000003",
    name: "Store Manager Ravi",
  },
  "EMP-005": {
    id: certId(305),
    phone: "919900000005",
    name: "Sales Executive Priya",
  },
  "EMP-006": {
    id: certId(306),
    phone: "919900000006",
    name: "Replay Tester",
  },
  "EMP-008": {
    id: certId(308),
    phone: "919900000008",
    name: "UOM Probe Executive",
  },
  "EMP-009": {
    id: certId(309),
    phone: "919900000009",
    name: "Frozen Policy Probe",
  },
};

export const CERT_CUSTOMERS: Record<string, CustomerRef> = {
  "CUST-ACTIVE-001": {
    id: certId(201),
    ref: "CUST-ACTIVE-001",
    business_name: "Taj Sweets Bengaluru",
    gst_number: "29ABCDE1234F1Z5",
    company_phone: "919800000001",
    payment_terms: "credit",
    is_frozen: false,
    branches: {
      "BR-001": {
        id: certId(211),
        label: "Main Store",
      },
    },
  },
  "CUST-ACTIVE-002": {
    id: certId(202),
    ref: "CUST-ACTIVE-002",
    business_name: "Oberoi Gourmet Foods",
    gst_number: "29FGHIJ5678K2Z6",
    company_phone: "919800000002",
    payment_terms: "credit",
    is_frozen: false,
    branches: {
      "BR-002": {
        id: certId(221),
        label: "Indiranagar Branch",
      },
      "BR-AMB": {
        id: certId(222),
        label: "Koramangala Branch",
      },
    },
  },
  "CUST-ACTIVE-003": {
    id: certId(203),
    ref: "CUST-ACTIVE-003",
    business_name: "Spice Route Retail",
    gst_number: "29LMNOP9012P3Z7",
    company_phone: "919800000003",
    payment_terms: "credit",
    is_frozen: false,
    branches: {
      "BR-003": {
        id: certId(231),
        label: "Main Depot",
      },
    },
  },
  "CUST-FROZEN-001": {
    id: certId(204),
    ref: "CUST-FROZEN-001",
    business_name: "Frozen Sweets Mart",
    gst_number: "29KLMNO9012P3Z7",
    company_phone: "919800000004",
    payment_terms: "credit",
    is_frozen: true,
    branches: {
      "BR-FRZ": {
        id: certId(241),
        label: "Main",
      },
    },
  },
  "CUST-SHARED-A": {
    id: certId(205),
    ref: "CUST-SHARED-A",
    business_name: "Alpha Traders",
    gst_number: "29AAAAA0000A1Z1",
    company_phone: "919800000099",
    payment_terms: "prepaid",
    is_frozen: false,
    branches: {
      "BR-A": {
        id: certId(251),
        label: "Alpha Main",
      },
    },
  },
  "CUST-SHARED-B": {
    id: certId(206),
    ref: "CUST-SHARED-B",
    business_name: "Beta Traders",
    gst_number: "29BBBBB1111B2Z2",
    company_phone: "919800000099",
    payment_terms: "prepaid",
    is_frozen: false,
    branches: {
      "BR-B": {
        id: certId(261),
        label: "Beta Main",
      },
    },
  },
};

export const CERT_PRODUCTS: Record<string, ProductRef> = {
  "PISTA-250": {
    id: certId(101),
    ref: "PISTA-250",
    sku: "BAK-PIST-250",
    name: "Pistachio Baklawa 250g",
    selling_price: 500,
    moq: 5,
    pricing_rule_id: certId(161),
    moq_rule_id: certId(171),
  },
  "MIX-500": {
    id: certId(104),
    ref: "MIX-500",
    sku: "MIX-ASST-500",
    name: "Special Assorted Mix",
    selling_price: 750,
    moq: 1,
    pricing_rule_id: certId(164),
    moq_rule_id: certId(174),
  },
  "MIX-1000": {
    id: certId(105),
    ref: "MIX-1000",
    sku: "MIX-ASST-1000",
    name: "Special Assorted Mix",
    selling_price: 1400,
    moq: 1,
    pricing_rule_id: certId(165),
    moq_rule_id: certId(175),
  },
};

export function customerRefForCompanyId(
  companyId: string | null | undefined,
): string | null {
  if (!companyId) return null;
  for (const customer of Object.values(CERT_CUSTOMERS)) {
    if (customer.id === companyId) return customer.ref;
  }
  return null;
}

export function branchRefForLabel(
  customerRef: string | null,
  label: string | null | undefined,
): string | null {
  if (!customerRef || !label) return null;
  const customer = CERT_CUSTOMERS[customerRef];
  if (!customer) return null;
  for (const [ref, branch] of Object.entries(customer.branches)) {
    if (branch.label === label) return ref;
  }
  return null;
}

export function productRefForSku(
  sku: string | null | undefined,
): string | null {
  if (!sku) return null;
  for (const product of Object.values(CERT_PRODUCTS)) {
    if (product.sku === sku) return product.ref;
  }
  return null;
}
