import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const outDir = 'artifacts/step1-certification';
const REDACTED = '[REDACTED]';

function secretVariants(dbUrl = '') {
  const values = new Set();
  if (dbUrl) values.add(dbUrl);
  try {
    const parsed = new URL(dbUrl);
    if (parsed.password) {
      values.add(parsed.password);
      try { values.add(decodeURIComponent(parsed.password)); } catch {}
    }
    if (parsed.username) values.add(`${parsed.username}:${parsed.password}`);
  } catch {}
  return [...values].filter(Boolean).sort((a, b) => b.length - a.length);
}

function redact(value, dbUrl = process.env.SUPABASE_DB_URL ?? '') {
  let text = String(value ?? '');
  for (const secret of secretVariants(dbUrl)) text = text.split(secret).join(REDACTED);
  // Defense in depth: redact PostgreSQL connection URIs even if their exact encoding differs.
  text = text.replace(/postgres(?:ql)?:\/\/[^\s'"`<>]+/gi, 'postgresql://[REDACTED]');
  return text;
}

function sanitizeTree(dir, dbUrl) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    const info = statSync(path);
    if (info.isDirectory()) sanitizeTree(path, dbUrl);
    else if (info.isFile()) {
      const original = readFileSync(path, 'utf8');
      const cleaned = redact(original, dbUrl);
      if (cleaned !== original) writeFileSync(path, cleaned, { mode: 0o600 });
    }
  }
}

function assertNoSecret(dir, dbUrl) {
  if (!existsSync(dir)) return;
  const variants = secretVariants(dbUrl);
  for (const name of readdirSync(dir)) {
    const path = join(dir, name);
    const info = statSync(path);
    if (info.isDirectory()) assertNoSecret(path, dbUrl);
    else if (info.isFile()) {
      const content = readFileSync(path, 'utf8');
      for (const secret of variants) {
        if (content.includes(secret)) throw new Error(`Credential redaction regression in ${path}`);
      }
      if (/postgres(?:ql)?:\/\/[^\s'"`<>]+/i.test(content)) throw new Error(`Database URI redaction regression in ${path}`);
    }
  }
}

function selfTest() {
  const sentinel = 'SENTINEL_DB_PASSWORD_DO_NOT_LEAK';
  const fake = `postgresql://postgres.test:${sentinel}%40encoded@aws-1-ap-south-1.pooler.supabase.com:5432/postgres`;
  const sample = `failure: Command failed: psql ${fake}\npassword=${sentinel}@encoded`;
  const cleaned = redact(sample, fake);
  if (cleaned.includes(sentinel) || cleaned.includes(fake) || /postgres(?:ql)?:\/\/[^\s'"`<>]+/i.test(cleaned)) {
    throw new Error('Credential redaction self-test failed');
  }
  mkdirSync(outDir, { recursive: true });
  const testPath = join(outDir, 'redaction-self-test.txt');
  writeFileSync(testPath, sample, { mode: 0o600 });
  sanitizeTree(outDir, fake);
  assertNoSecret(outDir, fake);
  console.log('PASS: certification credential redaction self-test');
}

if (process.argv.includes('--self-test')) {
  selfTest();
  process.exit(0);
}

const dbUrl = process.env.SUPABASE_DB_URL ?? '';
const result = spawnSync(process.execPath, ['scripts/step1-certification/run.mjs'], {
  env: process.env,
  encoding: 'utf8',
  stdio: ['ignore', 'pipe', 'pipe'],
});

// Sanitize persisted evidence before GitHub can upload it.
sanitizeTree(outDir, dbUrl);
assertNoSecret(outDir, dbUrl);

// Never forward raw child output. Redact before writing to Actions logs.
if (result.stdout) process.stdout.write(redact(result.stdout, dbUrl));
if (result.stderr) process.stderr.write(redact(result.stderr, dbUrl));
if (result.error) process.stderr.write(`${redact(result.error.message, dbUrl)}\n`);

if (result.status !== 0) {
  console.error(`Step 1 staging certification failed with exit code ${result.status ?? 1}; credentials redacted.`);
  process.exit(result.status ?? 1);
}

console.log('PASS: certification process-boundary credential redaction verified');
