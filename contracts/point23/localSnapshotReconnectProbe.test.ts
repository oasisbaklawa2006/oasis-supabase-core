import { createClient, type SupabaseClient } from "npm:@supabase/supabase-js@2.95.0";
import { RealtimeConsumerSession } from "./realtimeChannelContract.ts";
import { signLocalSupabaseJwt } from "./localProbeJwt.ts";

/** Disposable probe client — no generated Database types in Core contract tests. */
type ProbeClient = SupabaseClient;

const TEAM_MEMBER_ID = "a0230000-0000-0000-0000-000000000003";
const BUYER_ID = "a0230000-0000-0000-0000-000000000002";
const TABLE = "whatsapp_inbound_messages";
const PROBE_PREFIX = "point23-snapshot-probe";

type ProbeEnv = {
  url: string;
  serviceRoleKey: string;
  anonKey: string;
  jwtSecret: string;
};

function probeEnv(): ProbeEnv | null {
  const url = Deno.env.get("POINT23_PROBE_SUPABASE_URL") ?? Deno.env.get("SUPABASE_URL");
  const serviceRoleKey = Deno.env.get("POINT23_PROBE_SERVICE_ROLE_KEY") ??
    Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  const anonKey = Deno.env.get("POINT23_PROBE_ANON_KEY") ?? Deno.env.get("SUPABASE_ANON_KEY");
  const jwtSecret = Deno.env.get("POINT23_PROBE_JWT_SECRET") ?? Deno.env.get("SUPABASE_JWT_SECRET");
  if (!url || !serviceRoleKey || !anonKey || !jwtSecret) return null;
  return { url, serviceRoleKey, anonKey, jwtSecret };
}

async function seedDisposableUsers(admin: ProbeClient): Promise<void> {
  const { error: authError } = await admin.auth.admin.createUser({
    id: TEAM_MEMBER_ID,
    email: "point23-team-probe@example.com",
    email_confirm: true,
    user_metadata: {},
  });
  if (authError && !authError.message.includes("already")) throw authError;

  const { error: buyerError } = await admin.auth.admin.createUser({
    id: BUYER_ID,
    email: "point23-buyer-probe@example.com",
    email_confirm: true,
    user_metadata: {},
  });
  if (buyerError && !buyerError.message.includes("already")) throw buyerError;

  const { error: usersError } = await admin.from("users").upsert([
    { id: TEAM_MEMBER_ID, role: "ADMIN" },
    { id: BUYER_ID, role: "B2B_BUYER" },
  ]);
  if (usersError) throw usersError;

  const { data: adminRole } = await admin.from("roles").select("id").eq("role_key", "admin").maybeSingle();
  if (!adminRole?.id) throw new Error("admin role missing for disposable probe seed");

  const { error: mapError } = await admin.from("user_role_map").upsert({
    user_id: TEAM_MEMBER_ID,
    role_id: adminRole.id,
  }, { onConflict: "user_id,role_id", ignoreDuplicates: true });
  if (mapError) throw mapError;
}

async function teamClient(env: ProbeEnv) {
  const teamJwt = await signLocalSupabaseJwt(TEAM_MEMBER_ID, "authenticated", env.jwtSecret);
  return createClient(env.url, env.anonKey, {
    global: { headers: { Authorization: `Bearer ${teamJwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });
}

Deno.test({
  name: "local snapshot reconnect probe: Central reloads authoritative REST snapshot and dedupes replay",
  ignore: probeEnv() === null,
}, async () => {
  const env = probeEnv()!;
  const admin: ProbeClient = createClient(env.url, env.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  await seedDisposableUsers(admin);
  const team = await teamClient(env);

  const providerMessageId = `${PROBE_PREFIX}-${crypto.randomUUID()}`;
  const { data: inserted, error: insertError } = await admin.from(TABLE).insert({
    provider_message_id: providerMessageId,
    sender_phone: "+919888877766",
    sender_name: "Point23 Snapshot Probe",
    message_body: "authoritative snapshot reconnect probe",
  }).select("id,created_at").single();
  if (insertError || !inserted) throw insertError ?? new Error("insert failed");

  const rowId = String(inserted.id);
  const version = String(inserted.created_at);

  let cleanupInvoked = false;
  const session = new RealtimeConsumerSession({
    consumerApplication: "Central",
    schema: "public",
    table: TABLE,
    scope: "snapshot-probe",
    onCleanup: () => {
      cleanupInvoked = true;
    },
  });
  session.loadSnapshot([]);
  if (session.applyDelta({
    schema: "public",
    table: TABLE,
    rowId,
    eventType: "INSERT",
    version,
    payload: inserted,
  }) !== "applied") {
    throw new Error("initial delta not applied");
  }
  session.dispose();
  if (!cleanupInvoked) throw new Error("cleanup not invoked on disconnect");

  const { data: snapshotRows, error: snapshotError } = await team
    .from(TABLE)
    .select("id,created_at")
    .eq("provider_message_id", providerMessageId);
  if (snapshotError || !snapshotRows?.length) {
    throw snapshotError ?? new Error("authoritative REST snapshot missing after reconnect");
  }

  const reconnected = new RealtimeConsumerSession({
    consumerApplication: "Central",
    schema: "public",
    table: TABLE,
    scope: "snapshot-probe",
  });
  reconnected.loadSnapshot(snapshotRows.map((row) => ({
    id: String(row.id),
    version: String(row.created_at),
  })));

  if (reconnected.applyDelta({
    schema: "public",
    table: TABLE,
    rowId,
    eventType: "INSERT",
    version,
    payload: inserted,
  }) !== "duplicate") {
    throw new Error("reconnect replay was not classified duplicate");
  }
  reconnected.dispose();
});

Deno.test({
  name: "local snapshot reconnect probe: AI Studio uses isolated scoped channel on same authority",
  ignore: probeEnv() === null,
}, async () => {
  const env = probeEnv()!;
  const admin: ProbeClient = createClient(env.url, env.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  await seedDisposableUsers(admin);

  const providerMessageId = `${PROBE_PREFIX}-studio-${crypto.randomUUID()}`;
  const { data: inserted, error: insertError } = await admin.from(TABLE).insert({
    provider_message_id: providerMessageId,
    sender_phone: "+919777766655",
    message_body: "AI Studio snapshot probe",
  }).select("id,created_at").single();
  if (insertError || !inserted) throw insertError ?? new Error("insert failed");

  const session = new RealtimeConsumerSession({
    consumerApplication: "AI Studio",
    schema: "public",
    table: TABLE,
    scope: "studio-snapshot-probe",
  });
  if (session.channelName !== "AI Studio:public.whatsapp_inbound_messages:studio-snapshot-probe") {
    throw new Error(`unexpected AI Studio channel: ${session.channelName}`);
  }
  session.loadSnapshot([{ id: String(inserted.id), version: String(inserted.created_at) }]);
  session.dispose();
});

Deno.test({
  name: "local snapshot reconnect probe: non-team buyer cannot load authoritative snapshot",
  ignore: probeEnv() === null,
}, async () => {
  const env = probeEnv()!;
  const admin: ProbeClient = createClient(env.url, env.serviceRoleKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  await seedDisposableUsers(admin);

  const providerMessageId = `${PROBE_PREFIX}-buyer-${crypto.randomUUID()}`;
  const { error: insertError } = await admin.from(TABLE).insert({
    provider_message_id: providerMessageId,
    sender_phone: "+919666655544",
    message_body: "buyer denial probe",
  });
  if (insertError) throw insertError;

  const buyerJwt = await signLocalSupabaseJwt(BUYER_ID, "authenticated", env.jwtSecret);
  const buyer = createClient(env.url, env.anonKey, {
    global: { headers: { Authorization: `Bearer ${buyerJwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data, error } = await buyer
    .from(TABLE)
    .select("id")
    .eq("provider_message_id", providerMessageId);
  if (error) throw error;
  if (data && data.length > 0) {
    throw new Error("non-team buyer unexpectedly read governed whatsapp inbound message");
  }
});
