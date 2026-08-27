export const LOCAL_SUPABASE_DB_PORT = 54322;

/** Production Supabase identifiers CERT-A must never mutate. */
export const FORBIDDEN_SUPABASE_PROJECT_REFS = [
  "tcxvcatsqqertcnycuop",
] as const;

export type CertDatabaseUrlSource =
  | "explicit"
  | "DATABASE_URL"
  | "SUPABASE_DB_URL"
  | "default";

export class CertDatabaseTargetError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "CertDatabaseTargetError";
  }
}

export interface ParsedPostgresTarget {
  raw: string;
  hostname: string;
  port: number;
  database: string;
  username: string;
}

function normalizeLoopbackHost(hostname: string): string {
  if (hostname === "[::1]") return "::1";
  return hostname.toLowerCase();
}

export function isLocalCertDatabaseHost(hostname: string): boolean {
  const host = normalizeLoopbackHost(hostname);
  return host === "localhost" || host === "127.0.0.1" || host === "::1";
}

export function parsePostgresTarget(databaseUrl: string): ParsedPostgresTarget {
  let parsed: URL;
  try {
    parsed = new URL(databaseUrl);
  } catch {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: malformed database URL",
    );
  }
  if (parsed.protocol !== "postgresql:" && parsed.protocol !== "postgres:") {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: unsupported database URL scheme",
    );
  }
  if (!parsed.hostname) {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: missing database host",
    );
  }
  const database = parsed.pathname.replace(/^\//, "");
  if (!database) {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: missing database name",
    );
  }
  return {
    raw: databaseUrl,
    hostname: parsed.hostname,
    port: parsed.port ? Number(parsed.port) : 5432,
    database,
    username: decodeURIComponent(parsed.username),
  };
}

function containsForbiddenProductionIdentifier(value: string): string | null {
  const lower = value.toLowerCase();
  for (const ref of FORBIDDEN_SUPABASE_PROJECT_REFS) {
    if (lower.includes(ref.toLowerCase())) return ref;
  }
  return null;
}

function assertNotProductionSupabaseTarget(target: ParsedPostgresTarget): void {
  for (
    const field of [
      target.raw,
      target.hostname,
      target.username,
      target.database,
    ]
  ) {
    const forbidden = containsForbiddenProductionIdentifier(field);
    if (forbidden) {
      throw new CertDatabaseTargetError(
        `CERT-A database target rejected: production Supabase identifier ${forbidden}`,
      );
    }
  }
}

function assertLocalCertTarget(target: ParsedPostgresTarget): void {
  if (!isLocalCertDatabaseHost(target.hostname)) {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: non-local host",
    );
  }
  if (target.port !== LOCAL_SUPABASE_DB_PORT) {
    throw new CertDatabaseTargetError(
      `CERT-A database target rejected: local certification database must use port ${LOCAL_SUPABASE_DB_PORT}`,
    );
  }
}

function readRemoteAllowlist(): string[] {
  const raw = Deno.env.get("WA_CERT_REMOTE_DATABASE_ALLOWLIST")?.trim() ?? "";
  if (!raw) return [];
  return raw.split(",").map((entry) => entry.trim().toLowerCase()).filter(
    Boolean,
  );
}

function remoteAllowlistMatches(
  target: ParsedPostgresTarget,
  allowlist: string[],
): boolean {
  const host = normalizeLoopbackHost(target.hostname);
  const hostPort = `${host}:${target.port}`;
  return allowlist.some((entry) => entry === host || entry === hostPort);
}

function assertRemoteCertTargetAllowed(target: ParsedPostgresTarget): void {
  const allowRemote = Deno.env.get("WA_CERT_ALLOW_REMOTE_DATABASE") === "true";
  const allowlist = readRemoteAllowlist();

  if (!allowRemote) {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: remote database not allowed (set WA_CERT_ALLOW_REMOTE_DATABASE=true with WA_CERT_REMOTE_DATABASE_ALLOWLIST to opt in)",
    );
  }
  if (allowlist.length === 0) {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: WA_CERT_REMOTE_DATABASE_ALLOWLIST is required for remote certification databases",
    );
  }
  if (!remoteAllowlistMatches(target, allowlist)) {
    throw new CertDatabaseTargetError(
      "CERT-A database target rejected: remote host does not match WA_CERT_REMOTE_DATABASE_ALLOWLIST",
    );
  }
}

export function assertCertDatabaseTargetAllowed(
  databaseUrl: string,
  _source?: CertDatabaseUrlSource,
): ParsedPostgresTarget {
  const target = parsePostgresTarget(databaseUrl);
  assertNotProductionSupabaseTarget(target);

  if (isLocalCertDatabaseHost(target.hostname)) {
    assertLocalCertTarget(target);
    return target;
  }

  assertRemoteCertTargetAllowed(target);
  return target;
}

export function resolveCertDatabaseUrl(
  databaseUrl?: string,
): { url: string; source: CertDatabaseUrlSource } {
  if (databaseUrl !== undefined && databaseUrl !== "") {
    return { url: databaseUrl, source: "explicit" };
  }
  const fromDatabaseUrl = Deno.env.get("DATABASE_URL");
  if (fromDatabaseUrl) {
    return { url: fromDatabaseUrl, source: "DATABASE_URL" };
  }
  const fromSupabaseDbUrl = Deno.env.get("SUPABASE_DB_URL");
  if (fromSupabaseDbUrl) {
    return { url: fromSupabaseDbUrl, source: "SUPABASE_DB_URL" };
  }
  return {
    url:
      `postgresql://postgres:postgres@127.0.0.1:${LOCAL_SUPABASE_DB_PORT}/postgres`,
    source: "default",
  };
}

export function validateCertDatabaseTarget(
  databaseUrl?: string,
): {
  url: string;
  source: CertDatabaseUrlSource;
  target: ParsedPostgresTarget;
} {
  const resolved = resolveCertDatabaseUrl(databaseUrl);
  const target = assertCertDatabaseTargetAllowed(
    resolved.url,
    resolved.source,
  );
  return { ...resolved, target };
}
