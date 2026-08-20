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
