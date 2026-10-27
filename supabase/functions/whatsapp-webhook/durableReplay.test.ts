/**
 * WA-100 / D1 regression tests: durable ownership is NOT processing completion.
 *
 * A provider retry must resume unfinished downstream work, never be acknowledged as a
 * duplicate while required effects are missing, and never repeat effects that already
 * happened. Runs the real entrypoint against the stubbed Supabase (testdata/).
 */

import {
  buildMetaPayload,
  type MetaMessage,
  readStats,
  withMediaServer,
  withWebhook,
} from "./testdata/harness.ts";

const COMPANY = "00000000-0000-4000-8000-0000000000c1";
const LEDGER = "00000000-0000-4000-8000-0000000000a1";
const SENDER = "000000000000";
const CUSTOMER = {
  WEBHOOK_MOCK_RESOLVED_COMPANY_ID: COMPANY,
};

function text(id: string, body: string): MetaMessage {
  return { id, from: SENDER, body };
}

function expectStatus(res: Response, expected: number, label: string) {
  if (res.status !== expected) {
    throw new Error(`${label}: expected HTTP ${expected}, got ${res.status}`);
  }
}

function expectStat(stats: Record<string, number>, key: string, expected: number, label: string) {
  const actual = stats[key] ?? 0;
  if (actual !== expected) {
    throw new Error(`${label}: expected ${key}=${expected}, got ${actual} (stats=${JSON.stringify(stats)})`);
  }
}

Deno.test("buffer write failure is never acknowledged and recovers on provider retry", async () => {
  await withWebhook({ WEBHOOK_MOCK_FAIL_BUFFER_INSERT_ONCE: "1" }, async ({ post, statsPath }) => {
    const payload = buildMetaPayload([text("wamid.FAKE_BUF_FAIL_1", "hello buffer")], []);

    const first = await post(payload);
    expectStatus(first, 503, "buffer failure must surface so the provider retries");
    const afterFirst = readStats(statsPath);
    expectStat(afterFirst, "whatsapp_buffer_inserts", 0, "failed buffer write");
    expectStat(afterFirst, "whatsapp_messages_inserts", 0, "no durable ack without the buffer");

    const second = await post(payload);
    expectStatus(second, 200, "retry after buffer recovery");
    const afterSecond = readStats(statsPath);
    expectStat(afterSecond, "whatsapp_buffer_inserts", 1, "recovered buffer write");
    expectStat(afterSecond, "whatsapp_messages_inserts", 1, "durable row after recovery");
  });
});

Deno.test("failure after the durable row is resumed on retry, then later retries are cheap duplicates", async () => {
  await withMediaServer(async ({ url }) => {
    await withWebhook({
      ...CUSTOMER,
      WEBHOOK_MOCK_FAIL_MEDIA_RPC_ONCE: "1",
    }, async ({ post, statsPath }) => {
      const payload = buildMetaPayload([{
        ...text("wamid.FAKE_RESUME_1", "need 10 boxes"),
        extra: { type: "image", image: { link: url, mime_type: "image/png" } },
      }], []);

      const first = await post(payload);
      if (first.status < 500) {
        throw new Error(`incomplete downstream work must not be acknowledged (got ${first.status})`);
      }
      const afterFirst = readStats(statsPath);
      expectStat(afterFirst, "whatsapp_messages_inserts", 1, "durable row exists after first attempt");
      expectStat(afterFirst, "media_state_rpcs_ok", 0, "media state not yet completed");

      // Provider retry: the durable row exists but processing never completed.
      const second = await post(payload);
      expectStatus(second, 200, "retry resumes unfinished work");
      const secondBody = await second.json();
      if (JSON.stringify(secondBody).includes("duplicate_wamid")) {
        throw new Error(`retry was acknowledged as duplicate while work was unfinished: ${JSON.stringify(secondBody)}`);
      }
      const afterSecond = readStats(statsPath);
      expectStat(afterSecond, "media_state_rpcs_ok", 1, "media state completed on resume");
      expectStat(afterSecond, "storage_objects_created", 1, "media object stored exactly once across attempts");
      expectStat(afterSecond, "client_interactions_inserts", 1, "interaction recorded exactly once");
      expectStat(afterSecond, "whatsapp_buffer_inserts", 1, "buffer exactly once");
      expectStat(afterSecond, "whatsapp_messages_inserts", 1, "durable row exactly once");

      // Processing is now complete: further provider retries are plain duplicates.
      const third = await post(payload);
      expectStatus(third, 200, "completed message retry");
      if (!JSON.stringify(await third.json()).includes("duplicate_wamid")) {
        throw new Error("a completed message must be acknowledged as a duplicate");
      }
      const afterThird = readStats(statsPath);
      expectStat(afterThird, "client_interactions_inserts", 1, "completed duplicate repeats nothing");
      expectStat(afterThird, "storage_objects_created", 1, "completed duplicate repeats nothing");
      expectStat(afterThird, "media_state_rpcs_ok", 1, "completed duplicate repeats nothing");
    });
  });
});

Deno.test("interaction note is best effort: a rejected note never blocks acknowledgement, and replays reuse one stable id", async () => {
  // Production's client_interactions CHECK rejects interaction_type "whatsapp" today, so the note
  // must stay non-blocking (see the comment in index.ts). The stable id keeps it idempotent.
  await withWebhook({ ...CUSTOMER, WEBHOOK_MOCK_FAIL_INTERACTION_INSERT_ONCE: "1" }, async ({ post, statsPath }) => {
    const payload = buildMetaPayload([text("wamid.FAKE_INTERACTION_1", "hello team")], []);

    expectStatus(await post(payload), 200, "rejected interaction note must not block acknowledgement");
    const stats = readStats(statsPath);
    expectStat(stats, "client_interactions_inserts", 0, "note rejected by the sink");
    expectStat(stats, "whatsapp_messages_inserts", 1, "durable row once");
    expectStat(stats, "whatsapp_buffer_inserts", 1, "buffer once");
    expectStat(stats, "completion_receipts", 1, "message completes despite the rejected note");
  });
});

Deno.test("ledger dispute replay after a pre-durable failure does not duplicate the dispute", async () => {
  await withWebhook({
    ...CUSTOMER,
    WEBHOOK_MOCK_LEDGER_ID: LEDGER,
    WEBHOOK_MOCK_FAIL_INBOUND_WAMIDS_ONCE: "wamid.FAKE_DISPUTE_1",
  }, async ({ post, statsPath }) => {
    const payload = buildMetaPayload([text("wamid.FAKE_DISPUTE_1", "ledger dispute: balance is wrong")], []);

    expectStatus(await post(payload), 503, "durable insert fails after the dispute step");
    expectStat(readStats(statsPath), "ledger_disputes_inserts", 1, "dispute raised on first attempt");

    expectStatus(await post(payload), 200, "retry");
    const stats = readStats(statsPath);
    expectStat(stats, "ledger_disputes_inserts", 1, "retry must not raise a second dispute");
    expectStat(stats, "whatsapp_messages_inserts", 1, "durable row once");
  });
});

Deno.test("dispute persistence is best effort today: a rejected dispute never blocks acknowledgement", async () => {
  // Production's governed-write trigger rejects the handler's direct ledger_disputes insert, so
  // failing the request on it would be a permanent 5xx (see the comment in index.ts).
  await withWebhook({
    ...CUSTOMER,
    WEBHOOK_MOCK_LEDGER_ID: LEDGER,
    WEBHOOK_MOCK_FAIL_DISPUTE_INSERT_ONCE: "1",
  }, async ({ post, statsPath }) => {
    const payload = buildMetaPayload([text("wamid.FAKE_DISPUTE_2", "ledger dispute: invoice mismatch")], []);

    expectStatus(await post(payload), 200, "rejected dispute must not block acknowledgement");
    const stats = readStats(statsPath);
    expectStat(stats, "ledger_disputes_inserts", 0, "rejected dispute write");
    expectStat(stats, "whatsapp_messages_inserts", 1, "durable row once");
    expectStat(stats, "completion_receipts", 1, "message completes");
  });
});

Deno.test("concurrent identical deliveries create each business effect once", async () => {
  await withMediaServer(async ({ url }) => {
    await withWebhook({
      ...CUSTOMER,
      WEBHOOK_MOCK_LEDGER_ID: LEDGER,
      // Every store operation yields, so the three deliveries truly overlap and all of them
      // pass the "already complete?" check before any receipt exists.
      WEBHOOK_MOCK_LATENCY_MS: "15",
    }, async ({ post, statsPath }) => {
      const payload = buildMetaPayload([{
        ...text("wamid.FAKE_CONCURRENT_1", "ledger dispute and need 10 boxes"),
        extra: { type: "image", image: { link: url, mime_type: "image/png" } },
      }], []);

      const results = await Promise.all([post(payload), post(payload), post(payload)]);
      for (const [index, res] of results.entries()) {
        expectStatus(res, 200, `concurrent delivery #${index + 1}`);
      }
      const stats = readStats(statsPath);
      expectStat(stats, "whatsapp_messages_inserts", 1, "concurrent durable rows");
      expectStat(stats, "whatsapp_buffer_inserts", 1, "concurrent buffer rows");
      expectStat(stats, "client_interactions_inserts", 1, "concurrent interactions");
      expectStat(stats, "ledger_disputes_inserts", 1, "concurrent disputes");
      expectStat(stats, "storage_objects_created", 1, "concurrent media objects");
    });
  });
});

Deno.test("batch with a failing second message resumes only unfinished work and repeats no effects", async () => {
  await withWebhook({
    ...CUSTOMER,
    WEBHOOK_MOCK_FAIL_INBOUND_WAMIDS_ONCE: "wamid.FAKE_BATCH_B",
  }, async ({ post, statsPath }) => {
    const payload = buildMetaPayload([
      text("wamid.FAKE_BATCH_A", "first message"),
      text("wamid.FAKE_BATCH_B", "second message"),
    ], [{ id: "wamid.FAKE_OUT_1", status: "sent" }]);

    expectStatus(await post(payload), 503, "second message durable failure");
    expectStat(readStats(statsPath), "client_interactions_inserts", 1, "first message fully processed");

    expectStatus(await post(payload), 200, "replay of mixed batch");
    const stats = readStats(statsPath);
    expectStat(stats, "client_interactions_inserts", 2, "each message has exactly one interaction");
    expectStat(stats, "whatsapp_buffer_inserts", 2, "each message buffered once");
    expectStat(stats, "whatsapp_messages_inserts", 2, "each message durable once");
  });
});
