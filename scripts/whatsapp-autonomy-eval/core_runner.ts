import postgres from "npm:postgres@3.4.5";
import { validateCertDatabaseTarget } from "./database_target.ts";
import {
  branchRefForLabel,
  CERT_ADMIN_USER,
  CERT_CUSTOMERS,
  CERT_EMPLOYEES,
  CERT_KNOWLEDGE,
  CERT_PRODUCTS,
  customerRefForCompanyId,
  productRefForSku,
} from "./master_catalog.ts";
import type { GoldenCase, ObservedResult } from "./types.ts";

type Sql = ReturnType<typeof postgres>;

/** Isolates persisted CERT IDs when sanitized and protected corpora share one DB. */
export type CertCorpusNamespace = "sanitized" | "protected";

const CORPUS_ID_OFFSET: Record<CertCorpusNamespace, number> = {
  sanitized: 0,
  protected: 50_000,
};

/** Case-index contribution stride — must stay below CORPUS_SALT_STRIDE. */
export const CASE_ID_STRIDE = 100;
/** Salt occupies a higher-order field than max caseIndex * CASE_ID_STRIDE. */
export const CORPUS_SALT_STRIDE = 10_000_000;
/** Stage-2 historical corpus upper bound (8,911 windows + headroom). */
export const STAGE2_MAX_CASE_INDEX = 10_000;

export function corpusEntitySalt(corpusHash?: string): number {
  if (!corpusHash) return 0;
  let hash = 0;
  for (const ch of corpusHash) {
    hash = (hash * 31 + ch.charCodeAt(0)) >>> 0;
  }
  return hash % 9000;
}

export function harnessEntityId(
  corpus: CertCorpusNamespace,
  caseIndex: number,
  entityKind: number,
  corpusHash?: string,
): string {
  const salt = corpus === "protected" ? corpusEntitySalt(corpusHash) : 0;
  const n = CORPUS_ID_OFFSET[corpus] + salt * CORPUS_SALT_STRIDE +
    caseIndex * CASE_ID_STRIDE + entityKind;
  return `b1100000-0000-0000-0000-${String(n).padStart(12, "0")}`;
}

/** Protected-corpus upsert: preserve inbound PK; update mutable fields only. */
export const PROTECTED_INBOUND_CONFLICT_CLAUSE =
  `on conflict (provider_message_id) do update set
          sender_phone = excluded.sender_phone,
          message_body = excluded.message_body,
          message_type = excluded.message_type`;

/** Harness entity IDs share this prefix — scoped reset must never CASCADE unrelated CERT-A rows. */
export const HARNESS_ENTITY_PREFIX = "b1100000-0000-0000-0000-";

export async function resetCertWhatsAppHarness(sql: Sql): Promise<void> {
  const prefixPattern = `${HARNESS_ENTITY_PREFIX}%`;
  const stage2Pattern = "stage2-%";

  // Local cert DB uses the postgres superuser; replica role disables append-only
  // triggers so harness-scoped DELETEs never CASCADE unrelated production rows.
  await sql.unsafe(`set session_replication_role = replica`);

  try {
    await sql.unsafe(
      `
      delete from public.whatsapp_order_autonomy_draft_execution_events e
      where e.packet_id::text like $1
         or e.interpretation_id::text like $1
         or e.autonomy_decision_id in (
           select d.id from public.whatsapp_order_autonomy_decisions d
           where d.id::text like $1
              or d.packet_id::text like $1
              or d.interpretation_id::text like $1
         )
    `,
      [prefixPattern],
    );

    await sql.unsafe(
      `
      delete from public.whatsapp_order_autonomy_draft_executions
      where id::text like $1
         or packet_id::text like $1
         or interpretation_id::text like $1
         or autonomy_decision_id in (
           select d.id from public.whatsapp_order_autonomy_decisions d
           where d.id::text like $1
              or d.packet_id::text like $1
              or d.interpretation_id::text like $1
         )
         or potential_order_id in (
           select id from public.whatsapp_potential_orders
           where source_message_id in (
             select id from public.whatsapp_inbound_messages
             where id::text like $1 or provider_message_id like $2
           )
         )
    `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
      delete from public.whatsapp_order_clarification_tasks
      where potential_order_id in (
        select id from public.whatsapp_potential_orders
        where source_message_id in (
          select id from public.whatsapp_inbound_messages
          where id::text like $1 or provider_message_id like $2
        )
      )
    `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
      delete from public.whatsapp_order_field_resolutions
      where potential_order_id in (
        select id from public.whatsapp_potential_orders
        where source_message_id in (
          select id from public.whatsapp_inbound_messages
          where id::text like $1 or provider_message_id like $2
        )
      )
    `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
      delete from public.whatsapp_order_field_evidence
      where potential_order_id in (
        select id from public.whatsapp_potential_orders
        where source_message_id in (
          select id from public.whatsapp_inbound_messages
          where id::text like $1 or provider_message_id like $2
        )
      )
    `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.whatsapp_order_autonomy_decisions
    where id::text like $1
       or packet_id::text like $1
       or interpretation_id::text like $1
       or potential_order_id in (
         select id from public.whatsapp_potential_orders
         where source_message_id in (
           select id from public.whatsapp_inbound_messages
           where id::text like $1 or provider_message_id like $2
         )
       )
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.whatsapp_potential_order_audit_log
    where potential_order_id in (
      select id from public.whatsapp_potential_orders
      where source_message_id in (
        select id from public.whatsapp_inbound_messages
        where id::text like $1 or provider_message_id like $2
      )
    )
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.sales_order_draft_lines
    where draft_id in (
      select sales_order_draft_id from public.whatsapp_potential_orders
      where sales_order_draft_id is not null
        and source_message_id in (
          select id from public.whatsapp_inbound_messages
          where id::text like $1 or provider_message_id like $2
        )
      union
      select id from public.sales_order_drafts where id::text like $1
    )
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.sales_order_drafts
    where id in (
      select sales_order_draft_id from public.whatsapp_potential_orders
      where sales_order_draft_id is not null
        and source_message_id in (
          select id from public.whatsapp_inbound_messages
          where id::text like $1 or provider_message_id like $2
        )
    )
    or id::text like $1
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.whatsapp_potential_orders
    where source_message_id in (
      select id from public.whatsapp_inbound_messages
      where id::text like $1 or provider_message_id like $2
    )
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.whatsapp_packet_ai_interpretations
    where id::text like $1
       or packet_id in (
         select packet_id from public.whatsapp_messages
         where id::text like $1 or provider_message_id like $2
       )
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.whatsapp_messages
    where id::text like $1 or provider_message_id like $2
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
    delete from public.whatsapp_inbound_messages
    where id::text like $1 or provider_message_id like $2
  `,
      [prefixPattern, stage2Pattern],
    );

    await sql.unsafe(
      `
      delete from public.whatsapp_contacts
      where id::text like $1
    `,
      [prefixPattern],
    );
  } finally {
    await sql.unsafe(`set session_replication_role = default`);
  }
}

export async function seedCertMasterData(sql: Sql): Promise<void> {
  await sql.unsafe(
    `insert into auth.users (id, email) values ($1, $2) on conflict do nothing`,
    [
      CERT_ADMIN_USER.id,
      CERT_ADMIN_USER.email,
    ],
  );
  await sql.unsafe(
    `
    insert into public.users (id, email, full_name, role)
    values ($1, $2, 'CERT-A Admin', 'admin')
    on conflict do nothing
  `,
    [CERT_ADMIN_USER.id, CERT_ADMIN_USER.email],
  );

  await sql`
    insert into public.whatsapp_intelligence_knowledge_snapshots (
      id, schema_version, lifecycle, knowledge, content_checksum,
      created_by, reviewed_by, reviewed_at, approved_by, approved_at
    ) values (
      ${CERT_KNOWLEDGE.snapshot_id},
      'wa-knowledge/v1',
      'APPROVED',
      ${sql.json(CERT_KNOWLEDGE.knowledge)},
      ${CERT_KNOWLEDGE.checksum},
      ${CERT_ADMIN_USER.id},
      ${CERT_ADMIN_USER.id},
      statement_timestamp(),
      ${CERT_ADMIN_USER.id},
      statement_timestamp()
    ) on conflict (id) do nothing
  `;
  await sql.unsafe(
    `select public.whatsapp_activate_intelligence_knowledge_snapshot($1)`,
    [CERT_KNOWLEDGE.snapshot_id],
  );

  for (const product of Object.values(CERT_PRODUCTS)) {
    await sql.unsafe(
      `
      insert into public.products (
        id, name, sku, category, hsn_code, uom, pack_size, moq, moq_packs,
        is_active, visible_in_catalog, is_catalogue_ready
      ) values (
        $1, $2, $3, 'Sweets', '1905', 'Box', '250g', 1, 1, true, true, true
      ) on conflict (id) do nothing
    `,
      [product.id, product.name, product.sku],
    );
    await sql.unsafe(
      `
      insert into public.product_pricing_rules (
        id, product_id, price_channel, price_type, base_price, calculated_price,
        uom, approval_status, valid_from
      ) values (
        $1, $2, 'b2b', 'standard', $3, $3, 'Box', 'approved', current_date - 1
      ) on conflict (id) do nothing
    `,
      [product.pricing_rule_id, product.id, product.selling_price],
    );
    await sql.unsafe(
      `
      insert into public.product_moq_rules (
        id, product_id, channel, moq_applicable, moq_value, moq_uom,
        increment_value, increment_uom, min_carton_qty
      ) values (
        $1, $2, 'b2b', true, $3, 'Box', 1, 'Box', null
      ) on conflict (id) do nothing
    `,
      [product.moq_rule_id, product.id, product.moq],
    );
  }

  for (const customer of Object.values(CERT_CUSTOMERS)) {
    await sql.unsafe(
      `
      insert into public.companies (
        id, business_name, gst_number, phone, payment_terms, status, is_frozen
      ) values ($1, $2, $3, $4, $5, 'active', $6)
      on conflict (id) do nothing
    `,
      [
        customer.id,
        customer.business_name,
        customer.gst_number,
        customer.company_phone,
        customer.payment_terms,
        customer.is_frozen,
      ],
    );
    for (const branch of Object.values(customer.branches)) {
      const isDefault = branch.label.includes("Main") ||
        branch.label.includes("Indiranagar");
      await sql.unsafe(
        `
        insert into public.delivery_addresses (
          id, company_id, label, street_address, city, state, pincode, is_default
        ) values (
          $1, $2, $3, '100 Test Road', 'Bengaluru', 'Karnataka', '560001', $4
        ) on conflict (id) do nothing
      `,
        [branch.id, customer.id, branch.label, isDefault],
      );
    }
  }

  for (const employee of Object.values(CERT_EMPLOYEES)) {
    const email = `cert-${employee.id.slice(-12)}@example.test`;
    await sql.unsafe(
      `insert into auth.users (id, email) values ($1, $2) on conflict do nothing`,
      [employee.id, email],
    );
    await sql.unsafe(
      `
      insert into public.users (id, email, full_name, role, phone)
      values ($1, $2, $3, 'sales_executive', $4)
      on conflict do nothing
    `,
      [employee.id, email, employee.name, employee.phone],
    );
  }
}

async function setServiceRole(sql: Sql): Promise<void> {
  await sql.unsafe(
    `select set_config('request.jwt.claims', $1, false)`,
    [JSON.stringify({ role: "service_role" })],
  );
}

export async function setServiceRoleForHarness(sql: Sql): Promise<void> {
  await setServiceRole(sql);
}

function firstLine(
  payload: Record<string, unknown>,
): Record<string, unknown> | null {
  const governed = payload.governed_facts;
  if (!governed || typeof governed !== "object") return null;
  const lines = (governed as Record<string, unknown>).order_lines;
  if (!Array.isArray(lines) || lines.length === 0) return null;
  const line = lines[0];
  return line && typeof line === "object"
    ? line as Record<string, unknown>
    : null;
}

async function loadPersistedAutonomyPayload(
  sql: Sql,
  packetId: string,
  interpretationId: string,
): Promise<Record<string, unknown> | null> {
  const rows = await sql.unsafe<
    {
      id: string;
      autonomy_outcome: string;
      governed_facts: Record<string, unknown>;
    }[]
  >(
    `
    select id::text, autonomy_outcome, governed_facts
    from public.whatsapp_order_autonomy_decisions
    where packet_id = $1::uuid and interpretation_id = $2::uuid
    limit 1
  `,
    [packetId, interpretationId],
  );
  const row = rows[0];
  if (!row) return null;
  return {
    autonomy_outcome: row.autonomy_outcome,
    governed_facts: row.governed_facts,
    autonomy_decision_id: row.id,
    idempotent_replay: false,
  };
}

function inventedCommercialLeaked(
  payload: Record<string, unknown>,
  paymentTerms: string | null,
): boolean {
  const governed = payload.governed_facts;
  if (!governed || typeof governed !== "object") return false;
  const customer = (governed as Record<string, unknown>).customer;
  if (customer && typeof customer === "object") {
    const terms = (customer as Record<string, unknown>).payment_terms;
    if (terms === "COD") return true;
  }
  const lines = (governed as Record<string, unknown>).order_lines;
  if (!Array.isArray(lines)) return false;
  for (const line of lines) {
    if (!line || typeof line !== "object") continue;
    const row = line as Record<string, unknown>;
    if ("unit_price" in row || "discount" in row) return true;
  }
  if (paymentTerms === "COD") return true;
  return false;
}

export async function executeGoldenCase(
  sql: Sql,
  testCase: GoldenCase,
  caseIndex: number,
  corpus: CertCorpusNamespace = "sanitized",
  corpusHash?: string,
): Promise<ObservedResult> {
  const input = testCase.input;
  const messageType = input.message_type ?? "text";
  const inboundId = harnessEntityId(corpus, caseIndex, 2, corpusHash);
  const messageId = harnessEntityId(corpus, caseIndex, 3, corpusHash);
  const interpretationId = harnessEntityId(corpus, caseIndex, 4, corpusHash);

  try {
    await setServiceRole(sql);

    let contactId: string;
    if (corpus === "protected") {
      contactId = harnessEntityId(corpus, caseIndex, 1, corpusHash);
      await sql.unsafe(
        `
        insert into public.whatsapp_contacts(id, phone_number, customer_name)
        values ($1, $2, $3)
        on conflict (id) do update set
          phone_number = excluded.phone_number,
          customer_name = excluded.customer_name
      `,
        [contactId, input.submitter_phone, input.submitter_name],
      );
    } else {
      const existingContact = await sql.unsafe<{ id: string }[]>(
        `select id::text from public.whatsapp_contacts where phone_number = $1 limit 1`,
        [input.submitter_phone],
      );
      contactId = existingContact[0]?.id ??
        harnessEntityId(corpus, caseIndex, 1, corpusHash);
      if (!existingContact[0]) {
        await sql.unsafe(
          `
          insert into public.whatsapp_contacts(id, phone_number, customer_name)
          values ($1, $2, $3)
          on conflict (id) do nothing
        `,
          [contactId, input.submitter_phone, input.submitter_name],
        );
      }
    }

    const inboundConflict = corpus === "protected"
      ? PROTECTED_INBOUND_CONFLICT_CLAUSE
      : "on conflict (id) do nothing";

    await sql.unsafe(
      `
      insert into public.whatsapp_inbound_messages(
        id, provider_message_id, sender_phone, message_body, message_type, received_at
      ) values ($1, $2, $3, $4, $5, statement_timestamp())
      ${inboundConflict}
    `,
      [
        inboundId,
        input.provider_message_id,
        input.submitter_phone,
        input.message_body,
        messageType,
      ],
    );

    const messageConflict = corpus === "protected"
      ? `on conflict (id) do update set
          contact_id = excluded.contact_id,
          message_type = excluded.message_type,
          content = excluded.content,
          provider_message_id = excluded.provider_message_id,
          packet_id = null`
      : "on conflict (id) do nothing";

    await sql.unsafe(
      `
      insert into public.whatsapp_messages(
        id, contact_id, direction, message_type, content, provider, provider_message_id,
        status, message_timestamp, created_at
      ) values (
        $1, $2, 'inbound', $3, $4, 'click2api', $5, 'received',
        statement_timestamp(), statement_timestamp()
      ) ${messageConflict}
    `,
      [
        messageId,
        contactId,
        messageType,
        input.message_body,
        input.provider_message_id,
      ],
    );

    await sql.unsafe(
      `select public.stitch_whatsapp_messages_atomic($1, array[$2::uuid], 300)`,
      [contactId, messageId],
    );

    const packetRows = await sql.unsafe<{ packet_id: string }[]>(
      `select packet_id::text from public.whatsapp_messages where id = $1`,
      [messageId],
    );
    const packetId = packetRows[0]?.packet_id;
    if (!packetId) {
      throw new Error("packet_id missing after stitch");
    }

    await sql`
      insert into public.whatsapp_packet_ai_interpretations(
        id, packet_id, content_fingerprint, provider_message_ids,
        interpretation, model_version, knowledge_snapshot_id,
        knowledge_snapshot_schema_version, knowledge_snapshot_content_checksum,
        interpretation_schema_version, prompt_policy_version, resolver_policy_version
      ) values (
        ${interpretationId},
        ${packetId},
        ${`fp-${testCase.id}`},
        ${sql.array([input.provider_message_id])},
        ${sql.json(JSON.parse(JSON.stringify(input.interpretation)))},
        'cert-model-v1',
        ${CERT_KNOWLEDGE.snapshot_id},
        'wa-knowledge/v1',
        ${CERT_KNOWLEDGE.checksum},
        'wa-interpretation/v1',
        'wa-prompt/v1',
        'core-a-autonomy/v1'
      ) on conflict (id) do nothing
    `;

    let payload: Record<string, unknown> = {};
    try {
      const payloadRows = await sql.unsafe<
        { payload: Record<string, unknown> }[]
      >(
        `select public.whatsapp_materialize_packet_ai_case($1::uuid, $2::uuid) as payload`,
        [packetId, interpretationId],
      );
      payload = payloadRows[0]?.payload ?? {};
    } catch (error) {
      const persisted = await loadPersistedAutonomyPayload(
        sql,
        packetId,
        interpretationId,
      );
      if (!persisted) throw error;
      payload = persisted;
    }
    const draftExecution = payload.draft_execution;
    const draft = draftExecution && typeof draftExecution === "object"
      ? draftExecution as Record<string, unknown>
      : null;
    const promoted = draft?.promoted_order_id ?? draft?.sales_order_draft_id;
    const autoActioned = draft?.execution_status === "PROMOTED" ||
      (typeof promoted === "string" && promoted.length > 0);

    const governedCustomer =
      payload.governed_facts && typeof payload.governed_facts === "object"
        ? (payload.governed_facts as Record<string, unknown>).customer
        : null;
    const companyId = governedCustomer && typeof governedCustomer === "object"
      ? (governedCustomer as Record<string, unknown>).company_id
      : null;
    const customerRef = customerRefForCompanyId(
      typeof companyId === "string" ? companyId : null,
    );
    const governedBranch =
      payload.governed_facts && typeof payload.governed_facts === "object"
        ? (payload.governed_facts as Record<string, unknown>).branch
        : null;
    const branchLabel = governedBranch && typeof governedBranch === "object"
      ? (governedBranch as Record<string, unknown>).label
      : null;
    const governedLine = firstLine(payload);
    const branchRef = branchRefForLabel(
      customerRef,
      typeof branchLabel === "string" ? branchLabel : null,
    );
    const sku = typeof governedLine?.sku === "string" ? governedLine.sku : null;
    const productRef = productRefForSku(sku);
    const quantity = typeof governedLine?.quantity === "number"
      ? governedLine.quantity
      : typeof governedLine?.quantity === "string"
      ? Number(governedLine.quantity)
      : null;
    const uom = typeof governedLine?.uom === "string"
      ? governedLine.uom
      : typeof governedLine?.unit === "string"
      ? governedLine.unit
      : null;

    let sellingPrice: number | null = null;
    let paymentTerms: string | null = null;
    const draftId = typeof draft?.sales_order_draft_id === "string"
      ? draft.sales_order_draft_id
      : null;
    if (draftId) {
      const lineRows = await sql.unsafe<
        { selling_price: string | null; payment_terms: string | null }[]
      >(
        `
        select l.ai_line_snapshot->>'selling_price' as selling_price,
               c.payment_terms
        from public.sales_order_draft_lines l
        join public.sales_order_drafts d on d.id = l.draft_id
        left join public.companies c on c.id = d.company_id
        where l.draft_id = $1::uuid
        limit 1
      `,
        [draftId],
      );
      sellingPrice = lineRows[0]?.selling_price
        ? Number(lineRows[0].selling_price)
        : null;
      paymentTerms = lineRows[0]?.payment_terms ?? null;
    } else if (
      payload.governed_facts && typeof payload.governed_facts === "object"
    ) {
      const customer = (payload.governed_facts as Record<string, unknown>)
        .customer;
      if (customer && typeof customer === "object") {
        paymentTerms = (customer as Record<string, unknown>).payment_terms as
          | string
          | null;
      }
    }

    const decisionId = typeof payload.autonomy_decision_id === "string"
      ? payload.autonomy_decision_id
      : null;
    let potentialOrderState: string | null = null;
    let potentialOrderDisposition: string | null = null;
    if (decisionId) {
      const poRows = await sql.unsafe<
        { state: string; disposition: string }[]
      >(
        `
        select po.state, po.disposition
        from public.whatsapp_order_autonomy_decisions d
        join public.whatsapp_potential_orders po on po.id = d.potential_order_id
        where d.id = $1::uuid
      `,
        [decisionId],
      );
      potentialOrderState = poRows[0]?.state ?? null;
      potentialOrderDisposition = poRows[0]?.disposition ?? null;
    }

    return {
      case_id: testCase.id,
      observed_core_outcome: typeof payload.autonomy_outcome === "string"
        ? payload.autonomy_outcome
        : null,
      observed_auto_actioned: autoActioned,
      observed_customer: customerRef,
      observed_branch: branchRef,
      observed_sku: productRef,
      observed_quantity: Number.isFinite(quantity) ? quantity : null,
      observed_uom: uom,
      potential_order_state: potentialOrderState,
      potential_order_disposition: potentialOrderDisposition,
      draft_id: draftId,
      promoted_order_id: typeof draft?.promoted_order_id === "string"
        ? draft.promoted_order_id
        : null,
      selling_price: sellingPrice,
      payment_terms: paymentTerms,
      invented_commercial_leaked: inventedCommercialLeaked(
        payload,
        paymentTerms,
      ),
      idempotent_replay: payload.idempotent_replay === true,
      error: null,
    };
  } catch (error) {
    return {
      case_id: testCase.id,
      observed_core_outcome: null,
      observed_auto_actioned: false,
      observed_customer: null,
      observed_branch: null,
      observed_sku: null,
      observed_quantity: null,
      observed_uom: null,
      potential_order_state: null,
      potential_order_disposition: null,
      draft_id: null,
      promoted_order_id: null,
      selling_price: null,
      payment_terms: null,
      invented_commercial_leaked: false,
      idempotent_replay: false,
      error: error instanceof Error ? error.message : String(error),
    };
  }
}

export function connectCertDatabase(databaseUrl?: string): Sql {
  const { url } = validateCertDatabaseTarget(databaseUrl);
  return postgres(url, { prepare: false, max: 1 });
}

export async function runSanitizedCases(
  cases: GoldenCase[],
  databaseUrl?: string,
  corpus: CertCorpusNamespace = "protected",
): Promise<ObservedResult[]> {
  const sql = connectCertDatabase(databaseUrl);
  try {
    await setServiceRoleForHarness(sql);
    await seedCertMasterData(sql);
    const results: ObservedResult[] = [];
    for (const [index, testCase] of cases.entries()) {
      results.push(await executeGoldenCase(sql, testCase, index + 1, corpus));
    }
    return results;
  } finally {
    await sql.end({ timeout: 5 });
  }
}
