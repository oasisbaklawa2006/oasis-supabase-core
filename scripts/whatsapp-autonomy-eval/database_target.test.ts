import {
  assertEquals,
  assertThrows,
} from "https://deno.land/std@0.224.0/assert/mod.ts";
import {
  assertCertDatabaseTargetAllowed,
  CertDatabaseTargetError,
  LOCAL_SUPABASE_DB_PORT,
  resolveCertDatabaseUrl,
  validateCertDatabaseTarget,
} from "./database_target.ts";

const LOCAL_URL =
  `postgresql://postgres:postgres@127.0.0.1:${LOCAL_SUPABASE_DB_PORT}/postgres`;

type EnvSnapshot = Map<string, string | undefined>;

function snapshotEnv(keys: string[]): EnvSnapshot {
  const snapshot = new Map<string, string | undefined>();
  for (const key of keys) snapshot.set(key, Deno.env.get(key));
  return snapshot;
}

function restoreEnv(snapshot: EnvSnapshot): void {
  for (const [key, value] of snapshot) {
    if (value === undefined) Deno.env.delete(key);
    else Deno.env.set(key, value);
  }
}

function withEnv(
  values: Record<string, string | undefined>,
  fn: () => void,
): void {
  const keys = Object.keys(values);
  const snapshot = snapshotEnv(keys);
  for (const [key, value] of Object.entries(values)) {
    if (value === undefined) Deno.env.delete(key);
    else Deno.env.set(key, value);
  }
  try {
    fn();
  } finally {
    restoreEnv(snapshot);
  }
}

function testWithEnv(name: string, fn: () => void | Promise<void>): void {
  Deno.test({ name, permissions: { env: true } }, fn);
}

function assertRejectsRemote(url: string): void {
  assertThrows(
    () => assertCertDatabaseTargetAllowed(url),
    CertDatabaseTargetError,
  );
}

Deno.test("localhost on local Supabase port is accepted", () => {
  assertCertDatabaseTargetAllowed(
    `postgresql://postgres:postgres@localhost:${LOCAL_SUPABASE_DB_PORT}/postgres`,
  );
});

Deno.test("127.0.0.1 on local Supabase port is accepted", () => {
  assertCertDatabaseTargetAllowed(LOCAL_URL);
});

Deno.test("::1 on local Supabase port is accepted", () => {
  assertCertDatabaseTargetAllowed(
    `postgresql://postgres:postgres@[::1]:${LOCAL_SUPABASE_DB_PORT}/postgres`,
  );
});

testWithEnv("arbitrary remote PostgreSQL URL is rejected by default", () => {
  assertRejectsRemote(
    "postgresql://postgres:postgres@db.example.com:5432/postgres",
  );
});

testWithEnv("remote SUPABASE_DB_URL is rejected by default", () => {
  withEnv({
    DATABASE_URL: undefined,
    SUPABASE_DB_URL:
      "postgresql://postgres:postgres@cert-remote.example.com:5432/postgres",
    WA_CERT_ALLOW_REMOTE_DATABASE: undefined,
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: undefined,
  }, () => {
    const resolved = resolveCertDatabaseUrl();
    assertEquals(resolved.source, "SUPABASE_DB_URL");
    assertThrows(
      () => assertCertDatabaseTargetAllowed(resolved.url, resolved.source),
      CertDatabaseTargetError,
    );
  });
});

Deno.test("production-like Supabase target is rejected", () => {
  assertRejectsRemote(
    "postgresql://postgres:postgres@db.tcxvcatsqqertcnycuop.supabase.co:5432/postgres",
  );
  assertRejectsRemote(
    "postgresql://postgres.tcxvcatsqqertcnycuop:postgres@aws-0-eu-central-1.pooler.supabase.com:6543/postgres",
  );
});

Deno.test("malformed database URL is rejected", () => {
  assertThrows(
    () => assertCertDatabaseTargetAllowed("not-a-database-url"),
    CertDatabaseTargetError,
  );
  assertThrows(
    () =>
      assertCertDatabaseTargetAllowed(
        "https://example.com/not-postgres",
      ),
    CertDatabaseTargetError,
  );
});

testWithEnv(
  "remote certification target requires dual opt-in and exact allowlist",
  () => {
    const remoteUrl =
      "postgresql://postgres:postgres@cert-remote.example.com:5432/postgres";

    withEnv({
      WA_CERT_ALLOW_REMOTE_DATABASE: "true",
      WA_CERT_REMOTE_DATABASE_ALLOWLIST: "cert-remote.example.com",
    }, () => {
      assertCertDatabaseTargetAllowed(remoteUrl);
    });
  },
);

testWithEnv("partial remote opt-in is rejected", () => {
  const remoteUrl =
    "postgresql://postgres:postgres@cert-remote.example.com:5432/postgres";

  withEnv({
    WA_CERT_ALLOW_REMOTE_DATABASE: "true",
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: undefined,
  }, () => {
    assertRejectsRemote(remoteUrl);
  });

  withEnv({
    WA_CERT_ALLOW_REMOTE_DATABASE: undefined,
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: "cert-remote.example.com",
  }, () => {
    assertRejectsRemote(remoteUrl);
  });
});

testWithEnv("wrong remote allowlist is rejected", () => {
  withEnv({
    WA_CERT_ALLOW_REMOTE_DATABASE: "true",
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: "other-cert-db.example.com",
  }, () => {
    assertRejectsRemote(
      "postgresql://postgres:postgres@cert-remote.example.com:5432/postgres",
    );
  });
});

testWithEnv("DATABASE_URL alone does not authorize remote targets", () => {
  withEnv({
    DATABASE_URL:
      "postgresql://postgres:postgres@cert-remote.example.com:5432/postgres",
    SUPABASE_DB_URL: undefined,
    WA_CERT_ALLOW_REMOTE_DATABASE: undefined,
    WA_CERT_REMOTE_DATABASE_ALLOWLIST: undefined,
  }, () => {
    const resolved = resolveCertDatabaseUrl();
    assertEquals(resolved.source, "DATABASE_URL");
    assertThrows(
      () => assertCertDatabaseTargetAllowed(resolved.url, resolved.source),
      CertDatabaseTargetError,
    );
  });
});

testWithEnv("unsafe explicit databaseUrl is rejected before connection", () => {
  assertThrows(
    () =>
      validateCertDatabaseTarget(
        "postgresql://postgres:postgres@db.example.com:5432/postgres",
      ),
    CertDatabaseTargetError,
  );
});

testWithEnv("validateCertDatabaseTarget accepts default local fallback", () => {
  withEnv({
    DATABASE_URL: undefined,
    SUPABASE_DB_URL: undefined,
  }, () => {
    const resolved = validateCertDatabaseTarget();
    assertEquals(resolved.source, "default");
    assertEquals(resolved.target.hostname, "127.0.0.1");
    assertEquals(resolved.target.port, LOCAL_SUPABASE_DB_PORT);
  });
});
