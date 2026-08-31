import { CERT_CUSTOMERS } from "../whatsapp-autonomy-eval/master_catalog.ts";

export type CatalogCustomerMatch = {
  company_name: string;
  gst_number: string;
  branch_label?: string;
};

/** Deterministic CERT catalog match — no invented customers. */
export function matchCertCatalogCustomer(body: string): CatalogCustomerMatch | null {
  const lower = body.toLowerCase();
  for (const customer of Object.values(CERT_CUSTOMERS)) {
    if (lower.includes(customer.business_name.toLowerCase())) {
      const branch = Object.values(customer.branches).find((b) =>
        lower.includes(b.label.toLowerCase())
      );
      return {
        company_name: customer.business_name,
        gst_number: customer.gst_number,
        branch_label: branch?.label,
      };
    }
  }
  return null;
}

export function normalizeUom(raw: string): string {
  const unit = raw.toLowerCase();
  if (unit.startsWith("box")) return "box";
  if (unit.startsWith("kg")) return "kg";
  if (unit.startsWith("carton")) return "carton";
  if (unit.startsWith("piece") || unit === "pcs") return "piece";
  return unit.replace(/s$/, "");
}
