/**
 * Stage 1B controlled multimodal worker certification harness.
 * Targets isolated preview dfjslkwxawnzurolifpm only.
 */
import manifest from "./fixtures_manifest.json" with { type: "json" };
import postgres from "npm:postgres@3.4.5";
import {
  seedCertMasterData,
  setServiceRoleForHarness,
} from "../whatsapp-autonomy-eval/core_runner.ts";
import { validateCertDatabaseTarget } from "../whatsapp-autonomy-eval/database_target.ts";

const CERT_PROJECT_REF = "dfjslkwxawnzurolifpm";
const FORBIDDEN_PRODUCTION_REF = "tcxvcatsqqertcnycuop";
const BUCKET = "wa-stage1b-cert";
const FIXTURE_ROOT = Deno.env.get("WA_STAGE1B_FIXTURE_ROOT") ??
  "/tmp/wa-stage1b-cert-fixtures";
const ARTIFACT_DIR = "artifacts/wa-stage1b-cert";

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

type HarnessReport = {
  schema_version: "wa-stage1b-report/v1";
  status: "BLOCKED" | "COMPLETE" | "FAILED";
  blocker?: string;
  core_main?: string;
  cert_head?: string;
  cert_supabase: string;
  runtime_secret_readiness: Record<string, boolean>;
  fixture_count: number;
  image_only_count: number;
  pdf_count: number;
  audio_count: number;
  video_count: number;
  worker_invocations: number;
  dangerous_media_false_positives: number;
  results: unknown[];
  reconciliation?: Record<string, number>;
};

function requiredEnv(name: string): string {
  const value = Deno.env.get(name);
  if (!value) throw new Error(`MISSING_ENV:${name}`);
  return value;
}

function assertCertSupabaseUrl(url: string): void {
  const normalized = url.replace(/\/$/, "");
  if (!normalized.includes(CERT_PROJECT_REF)) {
    throw new Error(`CERT_TARGET_REJECTED:url must reference ${CERT_PROJECT_REF}`);
  }
  if (normalized.includes(FORBIDDEN_PRODUCTION_REF)) {
    throw new Error("CERT_TARGET_REJECTED:production ref forbidden");
  }
}

function secretReadiness(): Record<string, boolean> {
  return {
    SUPABASE_URL: Boolean(Deno.env.get("SUPABASE_URL")),
    SUPABASE_SERVICE_ROLE_KEY: Boolean(Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")),
    LOVABLE_API_KEY: Boolean(Deno.env.get("LOVABLE_API_KEY")),
    SUPABASE_ACCESS_TOKEN: Boolean(Deno.env.get("SUPABASE_ACCESS_TOKEN")),
    CLICK2API_API_KEY: Boolean(Deno.env.get("CLICK2API_API_KEY")),
    CLICK2API_ACCESS_TOKEN: Boolean(Deno.env.get("CLICK2API_ACCESS_TOKEN")),
    WA_CERT_ALLOW_REMOTE_DATABASE:
      Deno.env.get("WA_CERT_ALLOW_REMOTE_DATABASE") === "true",
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: Boolean(
      Deno.env.get("WA_CERT_REMOTE_DATABASE_ALLOWLIST"),
    ),
    DATABASE_URL: Boolean(Deno.env.get("DATABASE_URL")),
  };
}

async function probeWorkerReachable(
  supabaseUrl: string,
  serviceRoleKey: string,
): Promise<{ reachable: boolean; status: number; body: string }> {
  const response = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({}),
    },
  );
  const body = await response.text();
  return { reachable: response.status !== 404, status: response.status, body: body.slice(0, 200) };
}

async function uploadFixture(
  supabaseUrl: string,
  serviceRoleKey: string,
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

  const uploadUrl =
    `${supabaseUrl.replace(/\/$/, "")}/storage/v1/object/${BUCKET}/${filename}`;
  const response = await fetch(uploadUrl, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${serviceRoleKey}`,
      apikey: serviceRoleKey,
      "Content-Type": mime,
      "x-upsert": "true",
    },
    body: bytes,
  });
  if (!response.ok) {
    const detail = await response.text();
    throw new Error(`FIXTURE_UPLOAD_FAILED:${filename}:${response.status}:${detail.slice(0, 120)}`);
  }
  return `${supabaseUrl.replace(/\/$/, "")}/storage/v1/object/public/${BUCKET}/${filename}`;
}

async function invokeWorker(
  supabaseUrl: string,
  serviceRoleKey: string,
  packetId: string,
): Promise<Record<string, unknown>> {
  const response = await fetch(
    `${supabaseUrl.replace(/\/$/, "")}/functions/v1/whatsapp-packet-ai-worker`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceRoleKey}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ packet_id: packetId }),
    },
  );
  const text = await response.text();
  let data: Record<string, unknown> = {};
  try {
    data = JSON.parse(text) as Record<string, unknown>;
  } catch {
    data = { raw: text.slice(0, 500) };
  }
  if (!response.ok) {
    throw new Error(
      `WORKER_INVOKE_FAILED:${packetId}:${response.status}:${JSON.stringify(data).slice(0, 200)}`,
    );
  }
  return data;
}

function entityId(suffix: number): string {
  return `b2000000-0000-0000-0000-${String(suffix).padStart(12, "0")}`;
}

async function seedPacket(
  sql: Sql,
  fixture: Fixture,
  index: number,
  mediaUrls: string[],
): Promise<{ packetId: string; providerIds: string[] }> {
  const contactId = entityId(1000 + index);
  const packetId = entityId(2000 + index);
  const phone = `9199600${String(index).padStart(5, "0")}`;
  const providerIds = mediaUrls.map((_, i) => `wa-s1b-${fixture.id}-${i}`);

  await sql.unsafe(
    `insert into public.whatsapp_contacts(id, phone_number, customer_name)
     values ($1, $2, $3) on conflict do nothing`,
    [contactId, phone, `S1B ${fixture.id}`],
  );
  await sql.unsafe(
    `insert into public.whatsapp_message_packets(
       id, contact_id, stitched_content, fragment_count, first_message_at, last_message_at, status
     ) values ($1, $2, '{}'::jsonb, $3, statement_timestamp(), statement_timestamp(), 'open')
     on conflict do nothing`,
    [packetId, contactId, mediaUrls.length],
  );

  for (let i = 0; i < mediaUrls.length; i++) {
    const messageId = entityId(3000 + index * 10 + i);
    const inboundId = entityId(4000 + index * 10 + i);
    const providerId = providerIds[i];
    const mediaUrl = mediaUrls[i];
    const caption = i === 0 ? fixture.caption ?? "" : "";
    await sql.unsafe(
      `insert into public.whatsapp_inbound_messages(
         id, provider_message_id, sender_phone, message_body, message_type, received_at, raw_payload
       ) values ($1, $2, $3, $4, $5, statement_timestamp(), $6::jsonb)
       on conflict do nothing`,
      [
        inboundId,
        providerId,
        phone,
        caption || `[s1b ${fixture.media_type}]`,
        fixture.media_type,
        JSON.stringify({ media_url: mediaUrl, cert: "stage1b" }),
      ],
    );
    await sql.unsafe(
      `insert into public.whatsapp_messages(
         id, contact_id, packet_id, direction, message_type, content, provider,
         provider_message_id, media_url, status, packet_sequence, message_timestamp, created_at
       ) values (
         $1, $2, $3, 'inbound', $4, $5, 'cert-stage1b', $6, $7, 'received', $8,
         statement_timestamp(), statement_timestamp()
       ) on conflict do nothing`,
      [
        messageId,
        contactId,
        packetId,
        fixture.media_type,
        caption || `[s1b ${fixture.media_type}]`,
        providerId,
        mediaUrl,
        i + 1,
      ],
    );
  }

  if (fixture.follow_up_text) {
    const followProvider = `wa-s1b-${fixture.id}-follow`;
    const followMessageId = entityId(5000 + index);
    const followInboundId = entityId(6000 + index);
    await sql.unsafe(
      `insert into public.whatsapp_inbound_messages(
         id, provider_message_id, sender_phone, message_body, message_type, received_at
       ) values ($1, $2, $3, $4, 'text', statement_timestamp()) on conflict do nothing`,
      [followInboundId, followProvider, phone, fixture.follow_up_text],
    );
    await sql.unsafe(
      `insert into public.whatsapp_messages(
         id, contact_id, packet_id, direction, message_type, content, provider,
         provider_message_id, status, packet_sequence, message_timestamp, created_at
       ) values (
         $1, $2, $3, 'inbound', 'text', $4, 'cert-stage1b', $5, 'received',
         $6, statement_timestamp(), statement_timestamp()
       ) on conflict do nothing`,
      [
        followMessageId,
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

async function reconciliation(sql: Sql): Promise<Record<string, number>> {
  const rows = await sql.unsafe(`
    select
      (select unaccounted_potential_orders from public.whatsapp_potential_order_reconciliation) as unaccounted,
      (select count(*) from public.whatsapp_inbound_messages where sender_phone like '919960%') as inbound,
      (select count(*) from public.whatsapp_messages where provider='cert-stage1b') as messages
  `);
  const row = rows[0] as Record<string, number>;
  return {
    unaccounted_potential_orders: Number(row.unaccounted ?? 0),
    stage1b_messages: Number(row.messages ?? 0),
    stage1b_inbound: Number(row.inbound ?? 0),
  };
}

async function writeReport(report: HarnessReport): Promise<void> {
  await Deno.mkdir(ARTIFACT_DIR, { recursive: true });
  await Deno.writeTextFile(
    `${ARTIFACT_DIR}/report.json`,
    `${JSON.stringify(report, null, 2)}\n`,
  );
}

async function main(): Promise<void> {
  const readiness = secretReadiness();
  const report: HarnessReport = {
    schema_version: "wa-stage1b-report/v1",
    status: "BLOCKED",
    cert_supabase: CERT_PROJECT_REF,
    runtime_secret_readiness: readiness,
    fixture_count: 0,
    image_only_count: 0,
    pdf_count: 0,
    audio_count: 0,
    video_count: 0,
    worker_invocations: 0,
    dangerous_media_false_positives: 0,
    results: [],
  };

  const missing = [
    !readiness.SUPABASE_SERVICE_ROLE_KEY && "SUPABASE_SERVICE_ROLE_KEY",
    !readiness.LOVABLE_API_KEY && "LOVABLE_API_KEY",
    (!readiness.DATABASE_URL && !readiness.WA_CERT_ALLOW_REMOTE_DATABASE) &&
      "DATABASE_URL or WA_CERT_ALLOW_REMOTE_DATABASE",
  ].filter(Boolean) as string[];

  if (missing.length) {
    report.blocker = `Missing required secrets: ${missing.join(", ")}`;
    await writeReport(report);
    console.error(report.blocker);
    Deno.exit(1);
  }

  const supabaseUrl = Deno.env.get("SUPABASE_URL") ??
    `https://${CERT_PROJECT_REF}.supabase.co`;
  assertCertSupabaseUrl(supabaseUrl);
  const serviceRoleKey = requiredEnv("SUPABASE_SERVICE_ROLE_KEY");

  const probe = await probeWorkerReachable(supabaseUrl, serviceRoleKey);
  if (!probe.reachable) {
    report.blocker = "whatsapp-packet-ai-worker not reachable on cert preview";
    await writeReport(report);
    Deno.exit(1);
  }

  const fixtures = manifest.fixtures as Fixture[];
  report.fixture_count = fixtures.length;
  report.image_only_count = fixtures.filter((f) => f.media_type === "image").length;
  report.pdf_count = fixtures.filter((f) => f.media_type === "document").length;
  report.audio_count = fixtures.filter((f) => f.media_type === "audio").length;
  report.video_count = fixtures.filter((f) => f.media_type === "video").length;

  const gen = new Deno.Command("python3", {
    args: [new URL("./generate_fixtures.py", import.meta.url).pathname],
    env: { WA_STAGE1B_FIXTURE_ROOT: FIXTURE_ROOT },
  });
  const genOut = await gen.output();
  if (!genOut.success) {
    report.blocker = "Fixture generation failed; see generate_fixtures.py output";
    await writeReport(report);
    Deno.exit(1);
  }

  const { url: databaseUrl } = validateCertDatabaseTarget();
  const sql = postgres(databaseUrl);
  try {
    await setServiceRoleForHarness(sql);
    await seedCertMasterData(sql);

    for (const [index, fixture] of fixtures.entries()) {
      if (fixture.optional) continue;
      const filenames = fixture.files ?? (fixture.file ? [fixture.file] : []);
      const mediaUrls: string[] = [];
      for (const filename of filenames) {
        mediaUrls.push(await uploadFixture(supabaseUrl, serviceRoleKey, filename));
      }
      const { packetId } = await seedPacket(sql, fixture, index, mediaUrls);
      const workerResult = await invokeWorker(supabaseUrl, serviceRoleKey, packetId);
      report.worker_invocations += 1;
      report.results.push({
        fixture_id: fixture.id,
        packet_id: packetId,
        worker: workerResult,
        ground_truth: fixture.ground_truth,
      });
    }

    report.reconciliation = await reconciliation(sql);
    report.status = "COMPLETE";
    await writeReport(report);
    console.log(JSON.stringify(report, null, 2));
  } finally {
    await sql.end({ timeout: 5 });
  }
}

if (import.meta.main) {
  await main();
}
