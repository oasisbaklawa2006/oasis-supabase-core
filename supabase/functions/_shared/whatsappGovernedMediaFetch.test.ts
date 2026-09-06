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

Deno.test({
  name: "parseGovernedWhatsAppMediaUrl accepts loopback HTTP in historical cert mode",
  permissions: { env: true },
}, () => {
  const prior = Deno.env.get("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP");
  Deno.env.set("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP", "true");
  try {
    const url = parseGovernedWhatsAppMediaUrl(
      "http://127.0.0.1:54321/storage/v1/object/public/wa-hist-media-cert/sample.jpg", // pragma: allowlist secret
    );
    if (url.hostname !== "127.0.0.1") throw new Error("unexpected host");
  } finally {
    if (prior === undefined) Deno.env.delete("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP");
    else Deno.env.set("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP", prior);
  }
});

Deno.test({
  name: "parseGovernedWhatsAppMediaUrl accepts Supabase project storage host",
  permissions: { env: true },
}, () => {
  const prior = Deno.env.get("SUPABASE_URL");
  Deno.env.set("SUPABASE_URL", "https://jyezfiehhfgnvhzzffxr.supabase.co");
  try {
    const url = parseGovernedWhatsAppMediaUrl(
      "https://jyezfiehhfgnvhzzffxr.supabase.co/storage/v1/object/public/wa-stage1b-cert/fixture.png",
    );
    if (url.hostname !== "jyezfiehhfgnvhzzffxr.supabase.co") throw new Error("unexpected host");
  } finally {
    if (prior === undefined) Deno.env.delete("SUPABASE_URL");
    else Deno.env.set("SUPABASE_URL", prior);
  }
});

Deno.test({
  name: "parseGovernedWhatsAppMediaUrl accepts bracketed IPv6 loopback in cert mode",
  permissions: { env: true },
}, () => {
  const prior = Deno.env.get("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP");
  Deno.env.set("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP", "true");
  try {
    const url = parseGovernedWhatsAppMediaUrl(
      "http://[::1]:54321/storage/v1/object/public/wa-hist-media-cert/sample.jpg", // pragma: allowlist secret
    );
    if (url.hostname !== "[::1]") throw new Error("unexpected host");
  } finally {
    if (prior === undefined) Deno.env.delete("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP");
    else Deno.env.set("WA_HIST_MEDIA_CERT_ALLOW_LOOPBACK_HTTP", prior);
  }
});
