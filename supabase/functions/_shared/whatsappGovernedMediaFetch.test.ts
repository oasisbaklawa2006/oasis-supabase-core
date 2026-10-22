import {
  parseGovernedWhatsAppMediaUrl,
} from "./whatsappGovernedMediaFetch.ts";

Deno.test("parseGovernedWhatsAppMediaUrl rejects non-https URLs", () => {
  let threw = false;
  try {
    parseGovernedWhatsAppMediaUrl("http://lookaside.fbsbx.com/media");
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("expected protocol rejection");
});

Deno.test("parseGovernedWhatsAppMediaUrl rejects credentialed URLs", () => {
  let threw = false;
  try {
    parseGovernedWhatsAppMediaUrl("https://user:pass@click2api.in/media");
  } catch {
    threw = true;
  }
  if (!threw) throw new Error("expected credential rejection");
});

Deno.test("parseGovernedWhatsAppMediaUrl accepts allowlisted host", () => {
  const url = parseGovernedWhatsAppMediaUrl("https://lookaside.fbsbx.com/whatsapp/media/1");
  if (url.hostname !== "lookaside.fbsbx.com") throw new Error("unexpected host");
});

Deno.test("parseGovernedWhatsAppMediaUrl accepts Supabase project storage host", () => {
  const prior = Deno.env.get("SUPABASE_URL");
  Deno.env.set("SUPABASE_URL", "https://evmeoljyrvfiidxqzpya.supabase.co");
  try {
    const url = parseGovernedWhatsAppMediaUrl(
      "https://evmeoljyrvfiidxqzpya.supabase.co/storage/v1/object/public/wa-stage1b-cert/fixture.png",
    );
    if (url.hostname !== "evmeoljyrvfiidxqzpya.supabase.co") throw new Error("unexpected host");
  } finally {
    if (prior === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", prior);
  }
});

Deno.test("downloadGovernedWhatsAppMedia honours a caller timeout and never exceeds the default", async () => {
  const { downloadGovernedWhatsAppMedia } = await import(
    "./whatsappGovernedMediaFetch.ts"
  );
  const priorFetch = globalThis.fetch;
  const seen: AbortSignal[] = [];
  globalThis.fetch = ((_input: unknown, init?: RequestInit) => {
    const signal = init?.signal as AbortSignal;
    seen.push(signal);
    return new Promise<Response>((_resolve, reject) => {
      signal.addEventListener("abort", () => reject(signal.reason), {
        once: true,
      });
    });
  }) as typeof fetch;
  try {
    const started = Date.now();
    let failed = false;
    try {
      await downloadGovernedWhatsAppMedia(
        "https://lookaside.fbsbx.com/m/1",
        1024,
        40,
      );
    } catch {
      failed = true;
    }
    if (!failed) {
      throw new Error("a stalled fetch must be aborted at the caller timeout");
    }
    if (Date.now() - started > 2_000) {
      throw new Error("caller timeout was not applied");
    }
    if (seen.length !== 1) throw new Error("exactly one fetch expected");
  } finally {
    globalThis.fetch = priorFetch;
  }
});
