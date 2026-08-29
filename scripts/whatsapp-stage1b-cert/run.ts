/**
 * Stage 1B controlled multimodal worker certification harness.
 * Targets isolated preview dfjslkwxawnzurolifpm only.
 *
 * Important: the Lovable key belongs to the deployed Edge runtime, not this
 * harness process. The harness proves runtime readiness by invoking the worker.
 */
import manifest from "./fixtures_manifest.json" with { type: "json" };
import postgres from "npm:postgres@3.4.5";
import {
  createClient,
  type SupabaseClient,
} from "npm:@supabase/supabase-js@2.95.0";
import {
  seedCertMasterData,
  setServiceRoleForHarness,
} from "../whatsapp-autonomy-eval/core_runner.ts";
import { validateCertDatabaseTarget } from "../whatsapp-autonomy-eval/database_target.ts";
import { fanOutToStudioInbox } from "../../supabase/functions/_shared/studioInboxFanOut.ts";

const CERT_PROJECT_REF = "dfjslkwxawnzurolifpm";
const FORBIDDEN_PRODUCTION_REF = "tcxvcatsqqertcnycuop";
const BUCKET = "wa-stage1b-cert";
const FIXTURE_ROOT = Deno.env.get("WA_STAGE1B_FIXTURE_ROOT") ??
  "/tmp/wa-stage1b-cert-fixtures";
const ARTIFACT_DIR = "artifacts/wa-stage1b-cert";
const WORKER_PROBE_TIMEOUT_MS = 15_000;
const WORKER_INVOCATION_TIMEOUT_MS = 90_000;

type Sql = ReturnType<typeof postgres>;

type Fixture = {
  id: string;
  file?: string;
  files?: string[];
  media_type: string;
  caption?: string | null;
  follow_up_text?: string;
  optional?: boolean;
  ground_truth: Record<string, unknown>;
};

type PersistedOutcome = {
  interpretation_id: string | null;
  interpretation: Record<string, unknown> | null;
  autonomy_outcome: string | null;
  governed_facts: Record<string, unknown> | null;
  case_id: string | null;
  case_type: string | null;
  case_status: string | null;
  next_action: string | null;
  draft_id: string | null;
  draft_status: string | null;
  promoted_order_id: string | null;
};

type FixtureResult = {
  fixture_id: string;
  packet_id: string;
  provider_message_ids: string[];
  ground_truth: Record<string, unknown>;
  worker: Record<string, unknown>;
  persisted: PersistedOutcome;
  recognition: {
    intent: string | null;
    sku: string | null;
    product_name: string | null;
    quantity: number | null;
    uom: string | null;
  };
  scores: {
    intent_correct: boolean | null;
    product_family_correct: boolean | null;
    sku_correct: boolean | null;
    quantity_correct: boolean | null;
    uom_correct: boolean | null;
    clarification_correct: boolean | null;
    auto_actioned: boolean;
    auto_action_correct: boolean | null;
    invented_commercial_leakage: boolean;
    dangerous_false_positive: boolean;
  };
};

type HarnessReport = {
  schema_version: "wa-stage1b-report/v2";
  status: "BLOCKED" | "COMPLETE" | "FAILED";
  blocker?: string;
  core_main?: string;
  cert_head?: string;
  cert_supabase: string;
  run_id: string;
  runtime_secret_readiness: Record<string, boolean>;
  fixture_count: number;
  image_only_count: number;
  pdf_count: number;
  audio_count: number;
  video_count: number;
  worker_invocations: number;
  dangerous_media_false_positives: number;
  invented_commercial_leakage: number;
  metrics?: Record<string, number | null>;
  results: FixtureResult[];
  reconciliation?: Record<string, number>;
};

/** Reads one required harness environment variable without logging its value. */
function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`MISSING_ENV:${name}`);
  return value;
}

/** Hard-fails if any HTTP target can resolve to production instead of cert. */
function assertCertSupabaseUrl(url: string): void {
  const normalized = url.replace(/\/$/, "");
  if (!normalized.includes(CERT_PROJECT_REF)) {
    throw new Error(`CERT_TARGET_REJECTED:url must reference ${CERT_PROJECT_REF}`);
  }
  if (normalized.includes(FORBIDDEN_PRODUCTION_REF)) {
    throw new Error("CERT_TARGET_REJECTED:production ref forbidden");
  }
}

/** Returns secret/config presence only; never exposes secret values. */
function secretReadiness(): Record<string, boolean> {
  return {
    SUPABASE_SERVICE_ROLE_KEY: Boolean(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")),
    DATABASE_URL: Boolean(Deno.env.get("DATABASE_URL")),
    WA_CERT_ALLOW_REMOTE_DATABASE:
      Deno.env.get("WA_CERT_ALLOW_REMOTE_DATABASE") === "true",
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: Boolean(
      Deno.env.get("WA_CERT_REMOTE_DATABASE_ALLOWLIST"),
    ),
    SUPABASE_ACCESS_TOKEN: Boolean(Deno.env.get("SUPABASE_ACCESS_TOKEN")),
    CLICK2API_API_KEY: Boolean(Deno.env.get("CLICK2API_API_KEY")),
    CLICK2API_ACCESS_TOKEN: Boolean(Deno.env.get("CLICK2API_ACCESS_TOKEN")),
    WA_STAGE1B_DEVANAGARI_FONT: Boolean(Deno.env.get("WA_STAGE1B_DEVANAGARI_FONT")),
  };
}

/** Verifies service-role auth and current worker runtime configuration. */
async function probeWorkerRuntime(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<{ configured: boolean; status: number; error: string | null }> {
  let response: Response;
  try {
    response = await fetch(
      `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: "{}",
        signal: AbortSignal.timeout(WORKER_PROBE_TIMEOUT_MS),
      },
    );
  } catch (error) {
    throw new Error(
      `WORKER_PROBE_FAILED:${error instanceof Error ? error.message.slice(0, 120) : "NETWORK_ERROR"}`,
    );
  }

  const text = await response.text();
  let error: string | null = null;
  try {
    const parsed = JSON.parse(text) as Record<string, unknown>;
    error = typeof parsed.error === "string" ? parsed.error : null;
  } catch {
    error = text.slice(0, 120) || null;
  }

  if (response.status === 503 && error === "WORKER_NOT_CONFIGURED") {
    return { configured: false, status: response.status, error };
  }
  if (response.status === 400 && error === "PACKET_ID_REQUIRED") {
    return { configured: true, status: response.status, error };
  }
  if (response.status === 401 || response.status === 403) {
    throw new Error("WORKER_SERVICE_ROLE_AUTH_REJECTED");
  }
  if (response.status === 404) throw new Error("WORKER_NOT_DEPLOYED");
  throw new Error(
    `WORKER_PROBE_UNEXPECTED:${response.status}:${error ?? "NO_ERROR_CODE"}`,
  );
}

/** Creates the synthetic-only public bucket or verifies its public flag. */
async function ensurePublicBucket(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<void> {
  const base = supabaseUrl.replace(/\/$/, "");
  const headers = {
    Authorization: `Bearer ${serviceRoleKey}`,
    apikey: serviceRoleKey,
    "Content-Type": "application/json",
  };
  const current = await fetch(`${base}/storage/v1/bucket/${BUCKET}`, {
    headers,
    signal: AbortSignal.timeout(15_000),
  });
  if (current.ok) {
    const data = await current.json() as Record<string, unknown>;
    if (data.public !== true) throw new Error("CERT_FIXTURE_BUCKET_NOT_PUBLIC");
    return;
  }
  if (current.status !== 404) {
    throw new Error(`CERT_FIXTURE_BUCKET_LOOKUP_FAILED:${current.status}`);
  }
  const created = await fetch(`${base}/storage/v1/bucket`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      id: BUCKET,
      name: BUCKET,
      public: true,
      file_size_limit: 15 * 1024 * 1024,
      allowed_mime_types: [
        "image/png",
        "application/pdf",
        "audio/mpeg",
        "video/mp4",
      ],
    }),
    signal: AbortSignal.timeout(15_000),
  });
  if (!created.ok) {
    throw new Error(`CERT_FIXTURE_BUCKET_CREATE_FAILED:${created.status}`);
  }
}

/** Uploads one generated synthetic fixture and returns its cert-only public URL. */
async function uploadFixture(
  supabaseUrl: string,
  serviceRoleKey: string,
  runTag: string,
  filename: string,
): Promise<string> {
  const bytes = await Deno.readFile(`${FIXTURE_ROOT}/${filename}`);
  const ext = filename.split(".").pop()?.toLowerCase() ?? "bin";
  const mime = ext === "png"
    ? "image/png"
    : ext === "pdf"
    ? "application/pdf"
    : ext === "mp3"
    ? "audio/mpeg"
    : ext === "mp4"
    ? "video/mp4"
    : "application/octet-stream";
  const objectPath = `${runTag}/${filename}`;
  const base = supabaseUrl.replace(/\/$/, "");
  const response = await fetch(`${base}/storage/v1/object/${BUCKET}/${objectPath}`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
      "Content-Type": mime,
      "x-upsert": "false",
    },
    body: bytes,
    signal: AbortSignal.timeout(30_000),
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(
      `FIXTURE_UPLOAD_FAILED:${filename}:${response.status}:${detail.slice(0, 120)}`,
    );
  }
  return `${base}/storage/v1/object/public/${BUCKET}/${objectPath}`;
}

/** Claims the canonical durable dispatch lease and proves it belongs to this fixture. */
async function invokeClaimedWorker(
  supabaseUrl: string,
  serviceRoleKey: string,
  expectedPacketId: string,
): Promise<Record<string, unknown>> {
  let response: Response;
  try {
    response = await fetch(
      `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
      {
        method: "POST",
        headers: {
          Authorization: `Bearer ${serviceRoleKey}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({ claim_next: true }),
        signal: AbortSignal.timeout(WORKER_INVOCATION_TIMEOUT_MS),
      },
    );
  } catch (error) {
    throw new Error(
      `WORKER_INVOKE_NETWORK_FAILED:${expectedPacketId}:${error instanceof Error ? error.message.slice(0, 120) : "NETWORK_ERROR"}`,
    );
  }

  const text = await response.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text) as Record<string, unknown>;
  } catch {
    data = { raw: text.slice(0, 500) };
  }
  if (!response.ok) {
    throw new Error(
      `WORKER_INVOKE_FAILED:${expectedPacketId}:${response.status}:${JSON.stringify(data).slice(0, 220)}`,
    );
  }
  if (data.idle === true) throw new Error("DISPATCH_JOB_MISSING_AFTER_PACKET_SEED");
  if (data.packet_id !== expectedPacketId) {
    throw new Error(
      `DISPATCH_ORDER_CONTAMINATED:expected=${expectedPacketId}:got=${String(data.packet_id)}`,
    );
  }
  return data;
}

/** Determines whether the controlled ingress should create commercial evidence. */
function ingressCommercialEligible(fixture: Fixture): boolean {
  const intent = String(fixture.ground_truth.intent ?? "");
  if (["NEW_ORDER", "AMENDMENT", "CANCELLATION"].includes(intent)) return true;
  if (fixture.ground_truth.expect_clarification === true) return true;
  if (fixture.ground_truth.must_fail_closed === true) return true;
  return false;
}

/** Builds a deterministic synthetic Indian phone number scoped to the run. */
function runPhone(runTag: string, index: number): string {
  const seed = Number.parseInt(runTag.slice(0, 6), 16) % 900000000;
  const local = 7000000000 + ((seed * 100 + index) % 2999999999);
  return `91${String(local).slice(-10)}`;
}

/** Seeds one synthetic packet through Studio fan-out and canonical dispatch trigger. */
async function seedPacket(
  sql: Sql,
  admin: SupabaseClient,
  fixture: Fixture,
  index: number,
  mediaUrls: string[],
  runId: string,
  runTag: string,
): Promise<{ packetId: string; providerIds: string[] }> {
  const contactId = crypto.randomUUID();
  const packetId = crypto.randomUUID();
  const phone = runPhone(runTag, index);
  const providerIds = mediaUrls.map((_, i) => `wa-s1b-${runTag}-${fixture.id}-${i}`);
  const orderLikeHint = ingressCommercialEligible(fixture);

  await sql.unsafe(
    `insert into public.whatsapp_contacts(id, phone_number, customer_name)
     values ($1, $2, $3)`,
    [contactId, phone, `S1B ${fixture.id}`],
  );
  await sql.unsafe(
    `insert into public.whatsapp_message_packets(
       id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
     ) values ($1, $2, '{}'::jsonb, $3, statement_timestamp(), statement_timestamp(), 'open')`,
    [packetId, contactId, mediaUrls.length + (fixture.follow_up_text ? 1 : 0)],
  );

  for (let i = 0; i < mediaUrls.length; i++) {
    const providerId = providerIds[i];
    const caption = i === 0 ? fixture.caption ?? "" : "";
    await fanOutToStudioInbox({
      supabaseAdmin: admin,
      providerMessageId: providerId,
      senderPhone: phone,
      senderName: `S1B ${fixture.id}`,
      messageBody: caption,
      messageType: fixture.media_type,
      mediaCount: 1,
      conversationKey: `stage1b:${runTag}:${fixture.id}`,
      correctionOfProviderMessageId: null,
      rawPayload: {
        media_url: mediaUrls[i],
        cert: "stage1b",
        cert_run_id: runId,
      },
      timestampSec: Math.floor(Date.now() / 1000) + i,
      orderLikeHint,
      commercialRiskReason: orderLikeHint ? "CERT_STAGE1B_MEDIA_POTENTIAL" : null,
    });

    await sql.unsafe(
      `insert into public.whatsapp_messages(
         id, contact_id, packet_id, direction, message_type, content, provider,
         provider_message_id, media_url, status, packet_sequence, message_timestamp, created_at
       ) values (
         $1, $2, $3, 'inbound', $4, $5, 'cert-stage1b', $6, $7, 'received', $8,
         statement_timestamp(), statement_timestamp()
       )`,
      [
        crypto.randomUUID(),
        contactId,
        packetId,
        fixture.media_type,
        caption,
        providerId,
        mediaUrls[i],
        i + 1,
      ],
    );
  }

  if (fixture.follow_up_text) {
    const followProvider = `wa-s1b-${runTag}-${fixture.id}-follow`;
    await fanOutToStudioInbox({
      supabaseAdmin: admin,
      providerMessageId: followProvider,
      senderPhone: phone,
      senderName: `S1B ${fixture.id}`,
      messageBody: fixture.follow_up_text,
      messageType: "text",
      mediaCount: 0,
      conversationKey: `stage1b:${runTag}:${fixture.id}`,
      correctionOfProviderMessageId: providerIds[0] ?? null,
      rawPayload: { cert: "stage1b", cert_run_id: runId },
      timestampSec: Math.floor(Date.now() / 1000) + mediaUrls.length + 1,
      orderLikeHint: true,
      commercialRiskReason: "CERT_STAGE1B_CORRECTION",
    });
    await sql.unsafe(
      `insert into public.whatsapp_messages(
         id, contact_id, packet_id, direction, message_type, content, provider,
         provider_message_id, status, packet_sequence, message_timestamp, created_at
       ) values (
         $1, $2, $3, 'inbound', 'text', $4, 'cert-stage1b', $5, 'received',
         $6, statement_timestamp(), statement_timestamp()
       )`,
      [
        crypto.randomUUID(),
        contactId,
        packetId,
        fixture.follow_up_text,
        followProvider,
        mediaUrls.length + 1,
      ],
    );
    providerIds.push(followProvider);
  }

  return { packetId, providerIds };
}

/** Blocks on any pre-existing dispatch state so claim_next cannot cross-contaminate proof. */
async function assertNoOutstandingBacklog(sql: Sql): Promise<void> {
  const rows = await sql.unsafe<{
    id: string;
    state: string;
    provider_ids: string[] | null;
  }[]>(`
    select j.id::text, j.state,
           array_agg(m.provider_message_id order by m.provider_message_id)
             filter (where m.provider_message_id is not null) as provider_ids
      from public.whatsapp_packet_ai_dispatch_jobs j
      left join public.whatsapp_messages m on m.packet_id=j.packet_id
     where j.state in ('QUEUED','RETRY','BLOCKED_KNOWLEDGE_AUTHORITY','LEASED')
     group by j.id,j.state
     order by j.id
  `);
  if (!rows.length) return;

  const nonCert = rows.filter((row) => {
    const ids = row.provider_ids ?? [];
    return !ids.length || ids.some((id) =>
      !(id.startsWith("cert-") || id.startsWith("wa-s1b-"))
    );
  });
  if (nonCert.length) {
    throw new Error(`PREEXISTING_NONCERT_DISPATCH_BACKLOG:${nonCert.length}`);
  }
  throw new Error(`PREEXISTING_CERT_DISPATCH_BACKLOG:${rows.length}`);
}

/** Extracts the first interpreted or governed order line. */
function firstOrderLine(
  container: Record<string, unknown> | null,
): Record<string, unknown> | null {
  if (!container) return null;
  const conclusion = container.conclusion;
  const source = conclusion && typeof conclusion === "object"
    ? conclusion as Record<string, unknown>
    : container;
  const lines = source.order_lines;
  if (!Array.isArray(lines) || !lines.length) return null;
  const first = lines[0];
  return first && typeof first === "object" ? first as Record<string, unknown> : null;
}

/** Converts an observed quantity into a finite number or null. */
function numeric(value: unknown): number | null {
  if (typeof value === "number" && Number.isFinite(value)) return value;
  if (typeof value === "string" && value.trim() && Number.isFinite(Number(value))) {
    return Number(value);
  }
  return null;
}

/** Normalizes the advisory interpretation into scoring fields. */
function recognitionFrom(interpretation: Record<string, unknown> | null) {
  const conclusion = interpretation?.conclusion;
  const c = conclusion && typeof conclusion === "object"
    ? conclusion as Record<string, unknown>
    : null;
  const line = firstOrderLine(interpretation);
  return {
    intent: typeof c?.intent === "string" ? c.intent : null,
    sku: typeof line?.sku === "string" && line.sku.trim() ? line.sku.trim() : null,
    product_name: typeof line?.product_name === "string" && line.product_name.trim()
      ? line.product_name.trim()
      : null,
    quantity: numeric(line?.quantity),
    uom: typeof line?.unit === "string" && line.unit.trim()
      ? line.unit.trim()
      : typeof line?.uom === "string" && line.uom.trim()
      ? line.uom.trim()
      : null,
  };
}

/** Returns the first Core-governed order line, if any. */
function governedLine(
  governedFacts: Record<string, unknown> | null,
): Record<string, unknown> | null {
  if (!governedFacts) return null;
  const lines = governedFacts.order_lines;
  if (!Array.isArray(lines) || !lines.length) return null;
  return lines[0] && typeof lines[0] === "object"
    ? lines[0] as Record<string, unknown>
    : null;
}

/** Detects prohibited AI-origin commercial terms reaching Core-governed facts. */
function inventedCommercialLeakage(
  governedFacts: Record<string, unknown> | null,
): boolean {
  if (!governedFacts) return false;
  const customer = governedFacts.customer;
  if (customer && typeof customer === "object") {
    const terms = (customer as Record<string, unknown>).payment_terms;
    if (terms === "COD") return true;
  }
  const line = governedLine(governedFacts);
  return Boolean(line && ("unit_price" in line || "discount" in line));
}

/** Loads persisted AI, case, autonomy and draft outcomes for one fixture packet. */
async function loadPersistedOutcome(
  sql: Sql,
  packetId: string,
): Promise<PersistedOutcome> {
  const interpretations = await sql.unsafe<{
    id: string;
    interpretation: Record<string, unknown>;
  }[]>(
    `select id::text, interpretation
       from public.whatsapp_packet_ai_interpretations
      where packet_id=$1::uuid
      order by created_at desc
      limit 1`,
    [packetId],
  );
  const interpretationId = interpretations[0]?.id ?? null;
  const interpretation = interpretations[0]?.interpretation ?? null;

  const decisions = interpretationId
    ? await sql.unsafe<{
      autonomy_outcome: string;
      governed_facts: Record<string, unknown>;
    }[]>(
      `select autonomy_outcome, governed_facts
         from public.whatsapp_order_autonomy_decisions
        where packet_id=$1::uuid and interpretation_id=$2::uuid
        order by evaluated_at desc
        limit 1`,
      [packetId, interpretationId],
    )
    : [];

  const cases = await sql.unsafe<{
    id: string;
    case_type: string;
    status: string;
    next_action: string;
  }[]>(
    `select id::text, case_type, status, next_action
       from public.whatsapp_communication_cases
      where packet_id=$1::uuid
      order by updated_at desc
      limit 1`,
    [packetId],
  );

  const drafts = await sql.unsafe<{
    id: string;
    status: string;
    promoted_order_id: string | null;
  }[]>(
    `select id::text, status, promoted_order_id::text
       from public.sales_order_drafts
      where packet_id=$1::uuid
      order by created_at desc
      limit 1`,
    [packetId],
  );

  return {
    interpretation_id: interpretationId,
    interpretation,
    autonomy_outcome: decisions[0]?.autonomy_outcome ?? null,
    governed_facts: decisions[0]?.governed_facts ?? null,
    case_id: cases[0]?.id ?? null,
    case_type: cases[0]?.case_type ?? null,
    case_status: cases[0]?.status ?? null,
    next_action: cases[0]?.next_action ?? null,
    draft_id: drafts[0]?.id ?? null,
    draft_status: drafts[0]?.status ?? null,
    promoted_order_id: drafts[0]?.promoted_order_id ?? null,
  };
}

/** Compares one expected value with the observed normalized value. */
function boolScore(expected: unknown, observed: unknown): boolean | null {
  if (expected === undefined || expected === null) return null;
  if (typeof expected === "number") return numeric(observed) === expected;
  return String(observed ?? "").toLowerCase() === String(expected).toLowerCase();
}

/** Scores recognition plus dangerous Core authority outcomes against frozen truth. */
function scoreFixture(
  fixture: Fixture,
  persisted: PersistedOutcome,
): FixtureResult["scores"] {
  const gt = fixture.ground_truth;
  const rec = recognitionFrom(persisted.interpretation);
  const promoted = Boolean(persisted.promoted_order_id);
  const autoEligible = persisted.autonomy_outcome === "AUTO_ELIGIBLE";
  const authorityAdvanced = promoted || autoEligible;
  const line = governedLine(persisted.governed_facts);
  const governedSku = typeof line?.sku === "string" ? line.sku : null;
  const governedQty = numeric(line?.quantity);
  const governedUom = typeof line?.uom === "string"
    ? line.uom
    : typeof line?.unit === "string"
    ? line.unit
    : null;
  const leakage = inventedCommercialLeakage(persisted.governed_facts);

  let dangerous = false;
  if (authorityAdvanced) {
    if (
      gt.must_not_be_order === true || gt.must_fail_closed === true ||
      gt.expect_clarification === true || gt.must_not_widen_authority === true
    ) {
      dangerous = true;
    }
    if (gt.expect_auto === false) dangerous = true;
    if (gt.sku == null || gt.quantity == null) dangerous = true;
    if (gt.sku != null && !boolScore(gt.sku, governedSku)) dangerous = true;
    if (gt.quantity != null && !boolScore(gt.quantity, governedQty)) dangerous = true;
    if (gt.uom != null && !boolScore(gt.uom, governedUom)) dangerous = true;
    if (leakage) dangerous = true;
  }

  const autoActionCorrect = promoted ? !dangerous : null;

  return {
    intent_correct: boolScore(gt.intent, rec.intent),
    product_family_correct: gt.sku === "BAK-PIST-250"
      ? Boolean(
        rec.sku === "BAK-PIST-250" ||
          rec.product_name?.toLowerCase().includes("pistachio"),
      )
      : null,
    sku_correct: boolScore(gt.sku, rec.sku),
    quantity_correct: boolScore(gt.quantity, rec.quantity),
    uom_correct: boolScore(gt.uom, rec.uom),
    clarification_correct: gt.expect_clarification === true
      ? persisted.autonomy_outcome === "CLARIFICATION_REQUIRED"
      : null,
    auto_actioned: promoted,
    auto_action_correct: autoActionCorrect,
    invented_commercial_leakage: leakage,
    dangerous_false_positive: dangerous,
  };
}

/** Computes a ratio over only fields with explicit frozen ground truth. */
function percentage(values: Array<boolean | null>): number | null {
  const scored = values.filter((v): v is boolean => typeof v === "boolean");
  if (!scored.length) return null;
  return scored.filter(Boolean).length / scored.length;
}

/** Produces controlled-set metrics; these are not the historical 95% benchmark. */
function buildMetrics(results: FixtureResult[]): Record<string, number | null> {
  const imageOnly = results.filter((r) => {
    const fixture = (manifest.fixtures as Fixture[]).find((f) => f.id === r.fixture_id);
    return fixture?.media_type === "image" && !fixture.caption && !fixture.follow_up_text;
  });
  const auto = results.filter((r) => r.scores.auto_actioned);
  return {
    intent_accuracy: percentage(results.map((r) => r.scores.intent_correct)),
    product_family_accuracy: percentage(
      results.map((r) => r.scores.product_family_correct),
    ),
    exact_sku_accuracy: percentage(results.map((r) => r.scores.sku_correct)),
    quantity_accuracy: percentage(results.map((r) => r.scores.quantity_correct)),
    uom_accuracy: percentage(results.map((r) => r.scores.uom_correct)),
    clarification_correctness: percentage(
      results.map((r) => r.scores.clarification_correct),
    ),
    image_only_straight_through_rate: imageOnly.length
      ? imageOnly.filter((r) => r.scores.auto_actioned).length / imageOnly.length
      : null,
    controlled_media_auto_action_precision: auto.length
      ? auto.filter((r) => r.scores.auto_action_correct === true).length / auto.length
      : null,
  };
}

/** Reconciles only the current Stage-1B namespace plus the global zero-loss invariant. */
async function reconciliation(
  sql: Sql,
  runTag: string,
  packetIds: string[],
): Promise<Record<string, number>> {
  if (!packetIds.length) {
    return {
      orphan_raw_messages: 0,
      packets_without_case: 0,
      duplicate_drafts: 0,
      duplicate_promoted_orders: 0,
      unaccounted_potential_orders: 0,
    };
  }
  const rows = await sql.unsafe<{
    orphan_raw: string;
    packet_without_case: string;
    duplicate_drafts: string;
    duplicate_promotions: string;
    unaccounted: string;
  }[]>(
    `with run_raw as (
       select provider_message_id from public.whatsapp_inbound_messages
        where provider_message_id like $1
     ), run_packets as (
       select unnest($2::uuid[]) as packet_id
     )
     select
       (select count(*) from run_raw r where not exists (
          select 1 from public.whatsapp_messages m where m.provider_message_id=r.provider_message_id
        ))::text as orphan_raw,
       (select count(*) from run_packets p where not exists (
          select 1 from public.whatsapp_communication_cases c where c.packet_id=p.packet_id
        ))::text as packet_without_case,
       (select coalesce(sum(greatest(c-1,0)),0) from (
          select count(*) c from public.sales_order_drafts d
          join run_packets p on p.packet_id=d.packet_id group by d.packet_id
        ) x)::text as duplicate_drafts,
       (select coalesce(sum(greatest(c-1,0)),0) from (
          select count(*) c from public.sales_order_drafts d
          join run_packets p on p.packet_id=d.packet_id
           where d.promoted_order_id is not null group by d.packet_id
        ) x)::text as duplicate_promotions,
       (select unaccounted_potential_orders
          from public.whatsapp_potential_order_reconciliation)::text as unaccounted`,
    [`wa-s1b-${runTag}-%`, packetIds],
  );
  const row = rows[0];
  return {
    orphan_raw_messages: Number(row?.orphan_raw ?? 0),
    packets_without_case: Number(row?.packet_without_case ?? 0),
    duplicate_drafts: Number(row?.duplicate_drafts ?? 0),
    duplicate_promoted_orders: Number(row?.duplicate_promotions ?? 0),
    unaccounted_potential_orders: Number(row?.unaccounted ?? 0),
  };
}

/** Writes the authoritative partial/final Stage-1B JSON artifact. */
async function writeReport(report: HarnessReport): Promise<void> {
  await Deno.mkdir(ARTIFACT_DIR, { recursive: true });
  await Deno.writeTextFile(
    `${ARTIFACT_DIR}/report.json`,
    `${JSON.stringify(report, null, 2)}\n`,
  );
}

/** Generates current-run fixtures and retains bounded subprocess diagnostics. */
async function generateFixtures(): Promise<{ generated: string[]; skipped: string[] }> {
  const env: Record<string, string> = {
    WA_STAGE1B_FIXTURE_ROOT: FIXTURE_ROOT,
  };
  for (const name of ["WA_STAGE1B_AUDIO_FIXTURE", "WA_STAGE1B_DEVANAGARI_FONT"]) {
    const value = Deno.env.get(name);
    if (value) env[name] = value;
  }

  const gen = new Deno.Command("python3", {
    args: [new URL("./generate_fixtures.py", import.meta.url).pathname],
    env,
    stdout: "piped",
    stderr: "piped",
  });
  const output = await gen.output();
  const stdout = new TextDecoder().decode(output.stdout);
  const stderr = new TextDecoder().decode(output.stderr);
  if (!output.success) {
    throw new Error(
      `FIXTURE_GENERATION_FAILED:code=${output.code}:stdout=${stdout.slice(-1000)}:stderr=${stderr.slice(-1000)}`,
    );
  }
  return JSON.parse(stdout) as { generated: string[]; skipped: string[] };
}

/** Returns true only for image evidence with no caption or follow-up text. */
function isImageOnlyFixture(fixture: Fixture): boolean {
  return fixture.media_type === "image" && !fixture.caption && !fixture.follow_up_text;
}

/** Converts an unknown thrown value into a bounded artifact-safe error string. */
function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message.slice(0, 2000) : String(error).slice(0, 2000);
}

/** Executes one isolated Stage-1B run and always emits a final or partial report. */
async function main(): Promise<void> {
  const runId = Deno.env.get("WA_STAGE1B_RUN_ID") ?? crypto.randomUUID();
  const runTag = runId.replace(/[^0-9a-f]/gi, "").toLowerCase().slice(0, 12);
  const readiness = secretReadiness();
  const report: HarnessReport = {
    schema_version: "wa-stage1b-report/v2",
    status: "BLOCKED",
    cert_supabase: CERT_PROJECT_REF,
    run_id: runId,
    runtime_secret_readiness: readiness,
    fixture_count: 0,
    image_only_count: 0,
    pdf_count: 0,
    audio_count: 0,
    video_count: 0,
    worker_invocations: 0,
    dangerous_media_false_positives: 0,
    invented_commercial_leakage: 0,
    results: [],
  };

  let sql: Sql | null = null;
  const packetIds: string[] = [];
  let exitCode = 0;

  try {
    const remoteDatabaseReady = readiness.WA_CERT_ALLOW_REMOTE_DATABASE &&
      readiness.WA_CERT_REMOTE_DATABASE_ALLOWLIST;
    const missing = [
      !readiness.SUPABASE_SERVICE_ROLE_KEY && "SUPABASE_SERVICE_ROLE_KEY",
      (!readiness.DATABASE_URL && !remoteDatabaseReady) &&
        "DATABASE_URL or (WA_CERT_ALLOW_REMOTE_DATABASE=true and WA_CERT_REMOTE_DATABASE_ALLOWLIST)",
    ].filter(Boolean) as string[];
    if (missing.length) {
      throw new Error(`MISSING_HARNESS_CREDENTIALS:${missing.join(",")}`);
    }

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ??
      `https://${CERT_PROJECT_REF}.supabase.co`;
    assertCertSupabaseUrl(supabaseUrl);
    const { url: databaseUrl } = validateCertDatabaseTarget();
    const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

    const runtime = await probeWorkerRuntime(supabaseUrl, serviceRoleKey);
    report.runtime_secret_readiness.LOVABLE_API_KEY_EDGE_RUNTIME = runtime.configured;
    if (!runtime.configured) {
      throw new Error("MISSING_CERT_EDGE_RUNTIME_SECRET:LOVABLE_API_KEY");
    }

    const generated = await generateFixtures();
    const generatedSet = new Set(generated.generated);
    const fixtures = (manifest.fixtures as Fixture[]).filter((fixture) => {
      const names = fixture.files ?? (fixture.file ? [fixture.file] : []);
      return names.every((name) => generatedSet.has(name));
    });
    const missingMandatory = (manifest.fixtures as Fixture[]).filter((fixture) => {
      if (fixture.optional) return false;
      const names = fixture.files ?? (fixture.file ? [fixture.file] : []);
      return names.some((name) => !generatedSet.has(name));
    });
    if (missingMandatory.length) {
      throw new Error(
        `MANDATORY_FIXTURE_UNAVAILABLE:${missingMandatory.map((f) => f.id).join(",")}`,
      );
    }

    report.fixture_count = fixtures.length;
    report.image_only_count = fixtures.filter(isImageOnlyFixture).length;
    report.pdf_count = fixtures.filter((f) => f.media_type === "document").length;
    report.audio_count = fixtures.filter((f) => f.media_type === "audio").length;
    report.video_count = fixtures.filter((f) => f.media_type === "video").length;

    sql = postgres(databaseUrl);
    const admin = createClient(supabaseUrl, serviceRoleKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    await setServiceRoleForHarness(sql);
    await seedCertMasterData(sql);
    await assertNoOutstandingBacklog(sql);
    await ensurePublicBucket(supabaseUrl, serviceRoleKey);

    for (const [index, fixture] of fixtures.entries()) {
      const filenames = fixture.files ?? (fixture.file ? [fixture.file] : []);
      const mediaUrls: string[] = [];
      for (const filename of filenames) {
        mediaUrls.push(
          await uploadFixture(supabaseUrl, serviceRoleKey, runTag, filename),
        );
      }
      const { packetId, providerIds } = await seedPacket(
        sql,
        admin,
        fixture,
        index,
        mediaUrls,
        runId,
        runTag,
      );
      packetIds.push(packetId);
      const workerResult = await invokeClaimedWorker(
        supabaseUrl,
        serviceRoleKey,
        packetId,
      );
      report.worker_invocations += 1;
      const persisted = await loadPersistedOutcome(sql, packetId);
      const recognition = recognitionFrom(persisted.interpretation);
      const scores = scoreFixture(fixture, persisted);
      if (scores.dangerous_false_positive) {
        report.dangerous_media_false_positives += 1;
      }
      if (scores.invented_commercial_leakage) {
        report.invented_commercial_leakage += 1;
      }
      report.results.push({
        fixture_id: fixture.id,
        packet_id: packetId,
        provider_message_ids: providerIds,
        worker: workerResult,
        ground_truth: fixture.ground_truth,
        persisted,
        recognition,
        scores,
      });
    }

    report.metrics = buildMetrics(report.results);
    report.reconciliation = await reconciliation(sql, runTag, packetIds);
    const reconFailed = Object.values(report.reconciliation).some((value) =>
      value !== 0
    );
    report.status = report.dangerous_media_false_positives === 0 &&
        report.invented_commercial_leakage === 0 && !reconFailed
      ? "COMPLETE"
      : "FAILED";
    if (report.status !== "COMPLETE") {
      report.blocker = "CONTROLLED_MEDIA_SAFETY_OR_RECONCILIATION_FAILED";
      exitCode = 2;
    }
  } catch (error) {
    report.blocker = errorMessage(error);
    report.status = report.worker_invocations > 0 || report.results.length > 0
      ? "FAILED"
      : "BLOCKED";
    exitCode = 2;

    if (sql && packetIds.length) {
      try {
        report.reconciliation = await reconciliation(sql, runTag, packetIds);
      } catch (reconError) {
        report.blocker = `${report.blocker};PARTIAL_RECON_FAILED:${errorMessage(reconError)}`;
      }
    }
  } finally {
    if (sql) await sql.end({ timeout: 5 });
  }

  await writeReport(report);
  if (report.status === "COMPLETE") {
    console.log(JSON.stringify(report, null, 2));
  } else {
    console.error(JSON.stringify(report, null, 2));
  }
  if (exitCode !== 0) Deno.exit(exitCode);
}

if (import.meta.main) {
  await main();
}
