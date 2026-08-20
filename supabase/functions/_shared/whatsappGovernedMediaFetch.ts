/** @file Governed HTTPS media retrieval for WhatsApp B2B interpretation workers. */

export const DEFAULT_WHATSAPP_MEDIA_HOST_SUFFIXES = [
  "click2api.in",
  "lookaside.fbsbx.com",
] as const;

export type GovernedMediaPayload = {
  bytes: Uint8Array;
  mime: string;
};

/** Returns configured provider/CDN host suffixes from env plus defaults. */
export const configuredWhatsAppMediaHostSuffixes = (): string[] => {
  const configured = (Deno.env.get("WHATSAPP_MEDIA_ALLOWED_HOSTS") ?? "")
    .split(",")
    .map((host) => host.trim().toLowerCase().replace(/^\.+/, ""))
    .filter(Boolean);
  return [...new Set([...DEFAULT_WHATSAPP_MEDIA_HOST_SUFFIXES, ...configured])];
};

/** Parses and validates a WhatsApp provider media URL before any network fetch. skipcq: JS-R1005 */
export const parseGovernedWhatsAppMediaUrl = (mediaUrl: string): URL => {
  let parsed: URL;
  try {
    parsed = new URL(mediaUrl);
  } catch {
    throw new Error("MEDIA_URL_INVALID");
  }
  if (parsed.protocol !== "https:") {
    throw new Error("MEDIA_URL_PROTOCOL_NOT_ALLOWED");
  }
  if (parsed.username || parsed.password) {
    throw new Error("MEDIA_URL_CREDENTIALS_NOT_ALLOWED");
  }
  const hostname = parsed.hostname.toLowerCase().replace(/\.$/, "");
  const allowed = configuredWhatsAppMediaHostSuffixes().some(
    (suffix) => hostname === suffix || hostname.endsWith(`.${suffix}`),
  );
  if (!allowed) throw new Error("MEDIA_HOST_NOT_ALLOWED");
  return parsed;
};

/** Returns true when the host is the verified Click2API provider domain. */
export const isClick2ApiMediaHost = (hostname: string): boolean => {
  const host = hostname.toLowerCase();
  return host === "click2api.in" || host.endsWith(".click2api.in");
};

/** Reads a response body with a hard byte ceiling using bounded streaming. skipcq: JS-R1005 */
export const readBoundedResponseBody = async (
  response: Response,
  maxBytes: number,
): Promise<Uint8Array> => {
  if (!response.body) throw new Error("EMPTY_MEDIA");
  const reader = response.body.getReader();
  const chunks: Uint8Array[] = [];
  let total = 0;
  let doneReading = false;
  try {
    while (!doneReading) {
      const { done, value } = await reader.read();
      if (done) {
        doneReading = true;
        break;
      }
      if (value === undefined || value.byteLength === 0) continue;
      total += value.byteLength;
      if (total > maxBytes) {
        await reader.cancel("MEDIA_TOO_LARGE").catch(() => undefined);
        throw new Error("MEDIA_TOO_LARGE");
      }
      chunks.push(value);
    }
  } finally {
    reader.releaseLock();
  }
  if (!total) throw new Error("EMPTY_MEDIA");
  const bytes = new Uint8Array(total);
  let offset = 0;
  for (const chunk of chunks) {
    bytes.set(chunk, offset);
    offset += chunk.byteLength;
  }
  return bytes;
};

/** Builds Click2API provider headers when the media host requires them. */
const click2ApiProviderHeaders = (): Record<string, string> => {
  const providerHeaders: Record<string, string> = {};
  const click2ApiKey = Deno.env.get("CLICK2API_API_KEY");
  const accessToken = Deno.env.get("CLICK2API_ACCESS_TOKEN");
  if (click2ApiKey) providerHeaders.apikey = click2ApiKey;
  if (accessToken) providerHeaders.Authorization = `Bearer ${accessToken}`;
  return providerHeaders;
};

/**
 * Internal fetch helper. Caller must pass a URL already validated by
 * parseGovernedWhatsAppMediaUrl (HTTPS, allowlisted host, no credentials).
 */
const fetchValidatedHttpsResponse = async (
  validatedUrl: URL,
  providerHeaders: Record<string, string>,
): Promise<Response> => {
  const allowlistedHost = validatedUrl.hostname.toLowerCase();
  const hostAllowed = configuredWhatsAppMediaHostSuffixes().some(
    (suffix) =>
      allowlistedHost === suffix || allowlistedHost.endsWith(`.${suffix}`),
  );
  if (!hostAllowed || validatedUrl.protocol !== "https:") {
    throw new Error("MEDIA_HOST_NOT_ALLOWED");
  }
  // URL validated above (HTTPS + allowlisted host + no credentials in parseGovernedWhatsAppMediaUrl).
  return await fetch(validatedUrl.toString(), {
    headers: providerHeaders,
    redirect: "manual",
    signal: AbortSignal.timeout(20_000),
  });
};

/**
 * Downloads governed WhatsApp media after HTTPS/host/credential validation.
 * Redirects are rejected; only the validated URL is fetched. skipcq: JS-R1005
 */
// skipcq: JS-R1005
export const downloadGovernedWhatsAppMedia = async (
  mediaUrl: string,
  maxBytes: number,
): Promise<GovernedMediaPayload> => {
  const parsed = parseGovernedWhatsAppMediaUrl(mediaUrl);
  const providerHeaders = isClick2ApiMediaHost(parsed.hostname)
    ? click2ApiProviderHeaders()
    : {};

  const mediaResponse = await fetchValidatedHttpsResponse(
    parsed,
    providerHeaders,
  );
  if (mediaResponse.status >= 300 && mediaResponse.status < 400) {
    throw new Error("MEDIA_REDIRECT_NOT_ALLOWED");
  }
  if (!mediaResponse.ok) {
    throw new Error(`MEDIA_DOWNLOAD_${mediaResponse.status}`);
  }

  const declaredLength = Number(mediaResponse.headers.get("content-length"));
  if (Number.isFinite(declaredLength) && declaredLength > maxBytes) {
    throw new Error("MEDIA_TOO_LARGE");
  }

  const mime =
    (mediaResponse.headers.get("content-type") || "application/octet-stream")
      .split(";")[0]
      .trim()
      .toLowerCase();
  const bytes = await readBoundedResponseBody(mediaResponse, maxBytes);
  return { bytes, mime };
};
