/**
 * In-process Supabase client stub for whatsapp-webhook black-box tests.
 * Behaviour is driven by WEBHOOK_MOCK_* environment variables (no secrets).
 */

type Row = Record<string, unknown>;

export type WebhookMockConfig = {
  matchedProviderIds: Set<string>;
  failStatusRpc: boolean;
  failWhatsappMessagesInsert: boolean;
  failQuarantineInsert: boolean;
  failInboundInsertWamids: Set<string>;
  failInboundInsertOnceWamids: Set<string>;
  knownInboundWamids: Set<string>;
};

function readConfig(): WebhookMockConfig {
  const matched = new Set(
    (Deno.env.get("WEBHOOK_MOCK_MATCHED_PROVIDER_IDS") ?? "wamid.FAKE_OUT_1,wamid.FAKE_OUT_2")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const known = new Set(
    (Deno.env.get("WEBHOOK_MOCK_KNOWN_INBOUND_WAMIDS") ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const failWamids = new Set(
    (Deno.env.get("WEBHOOK_MOCK_FAIL_INBOUND_WAMIDS") ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  const failOnceWamids = new Set(
    (Deno.env.get("WEBHOOK_MOCK_FAIL_INBOUND_WAMIDS_ONCE") ?? "")
      .split(",")
      .map((s) => s.trim())
      .filter(Boolean),
  );
  return {
    matchedProviderIds: matched,
    failStatusRpc: Deno.env.get("WEBHOOK_MOCK_FAIL_STATUS_RPC") === "1",
    failWhatsappMessagesInsert: Deno.env.get("WEBHOOK_MOCK_FAIL_INBOUND_INSERT") === "1",
    failQuarantineInsert: Deno.env.get("WEBHOOK_MOCK_FAIL_QUARANTINE_INSERT") === "1",
    failInboundInsertWamids: failWamids,
    failInboundInsertOnceWamids: failOnceWamids,
    knownInboundWamids: known,
  };
}

const CONTACT_ID = "contact-fake-00000000-0000-4000-8000-000000000001";

/** Process-wide durable state so multi-request handler tests behave like production DB. */
const globalRecordedInboundWamids = new Set<string>();
const globalCapturedCommercialSources = new Set<string>();
const globalCommercialInboundProviderIds = new Set<string>();
const globalInsertedBufferIds = new Set<string>();
const globalRecordedDebugInboundWamids = new Set<string>();
const globalConsumedFailOnceWamids = new Set<string>();

function bumpStat(key: string, by = 1) {
  const path = Deno.env.get("WEBHOOK_MOCK_STATS_FILE");
  if (!path) return;
  let stats: Record<string, number> = {};
  try {
    stats = JSON.parse(Deno.readTextFileSync(path));
  } catch {
    stats = {};
  }
  stats[key] = (stats[key] ?? 0) + by;
  Deno.writeTextFileSync(path, JSON.stringify(stats));
}

class QueryChain {
  private filters: { col: string; val: unknown }[] = [];
  private op: "select" | "insert" | "update" = "select";
  private insertPayload: Row | Row[] | null = null;
  private updatePayload: Row | null = null;
  private limitN: number | null = null;
  private terminal: "maybeSingle" | "single" | "none" = "none";

  constructor(
    private readonly table: string,
    private readonly cfg: WebhookMockConfig,
  ) {}

  select(_columns: string) {
    return this;
  }

  insert(payload: Row | Row[]) {
    this.op = "insert";
    this.insertPayload = payload;
    return this;
  }

  update(payload: Row) {
    this.op = "update";
    this.updatePayload = payload;
    return this;
  }

  eq(column: string, value: unknown) {
    this.filters.push({ col: column, val: value });
    return this;
  }

  or(_expr: string) {
    return this;
  }

  in(_column: string, _values: unknown[]) {
    return this;
  }

  order(_column: string, _opts?: { ascending?: boolean }) {
    return this;
  }

  limit(n: number) {
    this.limitN = n;
    return this;
  }

  maybeSingle() {
    this.terminal = "maybeSingle";
    return this.resolve();
  }

  single() {
    this.terminal = "single";
    return this.resolve();
  }

  /** PostgREST builders are thenable when the chain ends without maybeSingle/single. */
  then<TResult1 = { data: unknown; error: unknown }, TResult2 = never>(
    onfulfilled?: ((value: { data: unknown; error: unknown }) => TResult1 | PromiseLike<TResult1>) | null,
    onrejected?: ((reason: unknown) => TResult2 | PromiseLike<TResult2>) | null,
  ): Promise<TResult1 | TResult2> {
    return this.resolve().then(onfulfilled, onrejected);
  }

  private resolve(): Promise<{ data: unknown; error: { code?: string; message: string } | null }> {
    if (this.op === "insert") {
      const row = Array.isArray(this.insertPayload) ? this.insertPayload[0] : this.insertPayload;
      if (this.table === "debug_webhooks" && row?.direction === "provider_status_unmatched") {
        if (this.cfg.failQuarantineInsert) {
          return Promise.resolve({ data: null, error: { message: "mock quarantine insert denied" } });
        }
        bumpStat("status_quarantine_inserts");
      }
      if (this.table === "whatsapp_buffer") {
        const stableId = typeof row?.id === "string" ? row.id : "";
        if (stableId && globalInsertedBufferIds.has(stableId)) {
          return Promise.resolve({
            data: null,
            error: { code: "23505", message: "duplicate buffer primary key" },
          });
        }
        if (stableId) globalInsertedBufferIds.add(stableId);
      }
      if (this.table === "whatsapp_messages" && this.cfg.failWhatsappMessagesInsert) {
        return Promise.resolve({
          data: null,
          error: { code: "42501", message: "mock inbound insert denied" },
        });
      }
      if (this.table === "whatsapp_messages") {
        const wamid = String(row?.provider_message_id ?? "");
        if (wamid && globalRecordedInboundWamids.has(wamid)) {
          return Promise.resolve({
            data: null,
            error: { code: "23505", message: "duplicate provider_message_id" },
          });
        }
        if (wamid && this.cfg.failInboundInsertWamids.has(wamid)) {
          return Promise.resolve({
            data: null,
            error: { code: "42501", message: "mock inbound insert denied for wamid" },
          });
        }
        if (wamid && this.cfg.failInboundInsertOnceWamids.has(wamid)
          && !globalConsumedFailOnceWamids.has(wamid)) {
          globalConsumedFailOnceWamids.add(wamid);
          return Promise.resolve({
            data: null,
            error: { code: "42501", message: "mock one-shot inbound insert denied for wamid" },
          });
        }
        if (wamid) globalRecordedInboundWamids.add(wamid);
      }
      const id = `row-${this.table}-${crypto.randomUUID()}`;
      if (this.table === "debug_webhooks") {
        bumpStat("debug_webhook_inserts");
        const inboundWamid = typeof row?.wamid === "string" ? row.wamid : "";
        if (inboundWamid && row?.direction === "inbound") {
          globalRecordedDebugInboundWamids.add(inboundWamid);
        }
      }
      if (this.table === "whatsapp_messages") bumpStat("whatsapp_messages_inserts");
      if (this.table === "whatsapp_buffer") bumpStat("whatsapp_buffer_inserts");
      if (this.terminal === "maybeSingle" || this.terminal === "single") {
        return Promise.resolve({ data: { id, ...row }, error: null });
      }
      return Promise.resolve({ data: null, error: null });
    }

    if (this.op === "update") {
      return Promise.resolve({ data: null, error: null });
    }

    if (this.table === "debug_webhooks") {
      const wamidFilter = this.filters.find((f) => f.col === "wamid");
      if (wamidFilter) {
        const wamid = String(wamidFilter.val);
        if (this.cfg.knownInboundWamids.has(wamid) || globalRecordedDebugInboundWamids.has(wamid)) {
          return Promise.resolve({ data: { id: "existing-debug-webhook" }, error: null });
        }
      }
      return Promise.resolve({ data: null, error: null });
    }

    if (this.table === "whatsapp_messages") {
      const providerFilter = this.filters.find((f) => f.col === "provider_message_id");
      if (providerFilter) {
        const providerId = String(providerFilter.val);
        if (globalRecordedInboundWamids.has(providerId)) {
          return Promise.resolve({ data: { id: `durable-${providerId}` }, error: null });
        }
      }
      return Promise.resolve({ data: null, error: null });
    }

    if (this.table === "whatsapp_inbound_messages") {
      const providerFilter = this.filters.find((f) => f.col === "provider_message_id");
      const providerId = String(providerFilter?.val ?? "");
      return Promise.resolve({
        data: globalCommercialInboundProviderIds.has(providerId)
          ? { id: `inbound-${providerId}` } : null,
        error: null,
      });
    }

    if (this.table === "whatsapp_contacts") {
      return Promise.resolve({ data: { id: CONTACT_ID }, error: null });
    }

    if (this.table === "users") {
      const rows = [];
      return Promise.resolve({ data: this.limitN === 1 ? rows : rows, error: null });
    }

    if (this.table === "companies" || this.table === "bi_monthly_ledgers" || this.table === "orders") {
      return Promise.resolve({ data: this.limitN === 1 ? null : [], error: null });
    }

    return Promise.resolve({ data: this.limitN === 1 ? null : [], error: null });
  }
}

class MockStorageBucket {
  upload() {
    return Promise.resolve({ data: null, error: null });
  }

  getPublicUrl(path: string) {
    return { data: { publicUrl: `https://example.test/storage/${path}` } };
  }
}

class MockAdminClient {
  constructor(private readonly cfg: WebhookMockConfig) {}

  from(table: string) {
    return new QueryChain(table, this.cfg);
  }

  async rpc(name: string, args: Record<string, unknown>) {
    if (name === "persist_whatsapp_operator_reply_provider_status") {
      bumpStat("status_rpc_calls");
      if (this.cfg.failStatusRpc) {
        return { data: null, error: { message: "mock status rpc failure" } };
      }
      const providerMessageId = String(args.p_provider_message_id ?? "");
      const matched = this.cfg.matchedProviderIds.has(providerMessageId);
      return {
        data: { matched, updated: matched, status: matched ? args.p_status : null },
        error: null,
      };
    }

    if (name === "ingest_whatsapp_inbound_message") {
      const providerId = String(args._provider_message_id ?? "unknown");
      globalCommercialInboundProviderIds.add(providerId);
      return {
        data: [{ id: `inbound-${providerId}` }],
        error: null,
      };
    }
    if (name === "capture_whatsapp_commercial_fragment") {
      const sourceId = String(args.p_source_message_id ?? "");
      if (!globalCapturedCommercialSources.has(sourceId)) {
        globalCapturedCommercialSources.add(sourceId);
        bumpStat("commercial_fragment_captures");
      }
      return { data: { id: `fragment-${sourceId}` }, error: null };
    }

    if (name === "whatsapp_resolve_governed_customer") {
      return {
        data: [{
          company_id: null,
          business_name: "Unknown",
          resolution_status: "UNRESOLVED",
          match_method: null,
        }],
        error: null,
      };
    }

    return { data: null, error: { message: `unexpected rpc ${name}` } };
  }

  storage = {
    from: (_bucket: string) => new MockStorageBucket(),
  };
}

export function createClient(_url: string, _key: string) {
  const cfg = readConfig();
  return new MockAdminClient(cfg);
}
