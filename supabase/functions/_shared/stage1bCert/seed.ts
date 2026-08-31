/** @file CERT master-data seed via service-role client — NON-PRODUCTION only. */

import type { SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import {
  CERT_ADMIN_USER,
  CERT_CUSTOMERS,
  CERT_EMPLOYEES,
  CERT_KNOWLEDGE,
  CERT_PRODUCTS,
} from "./certCatalog.ts";

export async function seedCertMasterData(admin: SupabaseClient): Promise<void> {
  await admin.auth.admin.createUser({
    id: CERT_ADMIN_USER.id,
    email: CERT_ADMIN_USER.email,
    email_confirm: true,
  }).catch(() => undefined);

  await admin.from("users").upsert({
    id: CERT_ADMIN_USER.id,
    email: CERT_ADMIN_USER.email,
    full_name: "CERT-A Admin",
    role: "admin",
  }, { onConflict: "id", ignoreDuplicates: true });

  const { data: existingKnowledge } = await admin
    .from("whatsapp_intelligence_knowledge_snapshots")
    .select("lifecycle")
    .eq("id", CERT_KNOWLEDGE.snapshot_id)
    .maybeSingle();

  const snapshotId = !existingKnowledge?.lifecycle ||
      existingKnowledge.lifecycle === "APPROVED" ||
      existingKnowledge.lifecycle === "ACTIVE"
    ? CERT_KNOWLEDGE.snapshot_id
    : crypto.randomUUID();

  await admin.from("whatsapp_intelligence_knowledge_snapshots").upsert({
    id: snapshotId,
    schema_version: "wa-knowledge/v1",
    lifecycle: "APPROVED",
    knowledge: CERT_KNOWLEDGE.knowledge,
    content_checksum: CERT_KNOWLEDGE.checksum,
    created_by: CERT_ADMIN_USER.id,
    reviewed_by: CERT_ADMIN_USER.id,
    reviewed_at: new Date().toISOString(),
    approved_by: CERT_ADMIN_USER.id,
    approved_at: new Date().toISOString(),
  }, { onConflict: "id", ignoreDuplicates: true });

  await admin.rpc("whatsapp_activate_intelligence_knowledge_snapshot", {
    p_snapshot_id: snapshotId,
  });

  for (const product of CERT_PRODUCTS) {
    await admin.from("products").upsert({
      id: product.id,
      name: product.name,
      sku: product.sku,
      category: "Sweets",
      hsn_code: "1905",
      uom: "Box",
      pack_size: "250g",
      moq: 1,
      moq_packs: 1,
      is_active: true,
      visible_in_catalog: true,
      is_catalogue_ready: true,
    }, { onConflict: "id", ignoreDuplicates: true });

    await admin.from("product_pricing_rules").upsert({
      id: product.pricing_rule_id,
      product_id: product.id,
      price_channel: "b2b",
      price_type: "standard",
      base_price: product.selling_price,
      calculated_price: product.selling_price,
      uom: "Box",
      approval_status: "approved",
      valid_from: new Date(Date.now() - 86400000).toISOString().slice(0, 10),
    }, { onConflict: "id", ignoreDuplicates: true });

    await admin.from("product_moq_rules").upsert({
      id: product.moq_rule_id,
      product_id: product.id,
      channel: "b2b",
      moq_applicable: true,
      moq_value: product.moq,
      moq_uom: "Box",
      increment_value: 1,
      increment_uom: "Box",
      min_carton_qty: null,
    }, { onConflict: "id", ignoreDuplicates: true });
  }

  for (const customer of CERT_CUSTOMERS) {
    await admin.from("companies").upsert({
      id: customer.id,
      business_name: customer.business_name,
      gst_number: customer.gst_number,
      phone: customer.company_phone,
      payment_terms: customer.payment_terms,
      status: "active",
      is_frozen: customer.is_frozen,
    }, { onConflict: "id", ignoreDuplicates: true });

    await admin.from("delivery_addresses").upsert({
      id: customer.branch_id,
      company_id: customer.id,
      label: customer.branch_label,
      street_address: "100 Test Road",
      city: "Bengaluru",
      state: "Karnataka",
      pincode: "560001",
      is_default: true,
    }, { onConflict: "id", ignoreDuplicates: true });
  }

  for (const employee of CERT_EMPLOYEES) {
    const email = `cert-${employee.id.slice(-12)}@example.test`;
    await admin.auth.admin.createUser({
      id: employee.id,
      email,
      email_confirm: true,
    }).catch(() => undefined);

    await admin.from("users").upsert({
      id: employee.id,
      email,
      full_name: employee.name,
      role: "sales_executive",
      phone: employee.phone,
    }, { onConflict: "id", ignoreDuplicates: true });
  }
}
