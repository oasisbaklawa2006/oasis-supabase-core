import { spawnSync } from 'node:child_process';
import { existsSync, mkdirSync, readFileSync, readdirSync, statSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

const outDir = 'artifacts/step1-certification';
const REDACTED = '[REDACTED]';
const sourceRunner = 'scripts/step1-certification/run.mjs';
const generatedRunner = 'scripts/step1-certification/.generated-run.mjs';

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
  return text.replace(/postgres(?:ql)?:\/\/[^\s'"`<>]+/gi, 'postgresql://[REDACTED]');
}
function sanitizeTree(dir, dbUrl) {
  if (!existsSync(dir)) return;
  for (const name of readdirSync(dir)) {
    const path = join(dir, name); const info = statSync(path);
    if (info.isDirectory()) sanitizeTree(path, dbUrl);
    else if (info.isFile()) { const original = readFileSync(path, 'utf8'); const cleaned = redact(original, dbUrl); if (cleaned !== original) writeFileSync(path, cleaned, { mode: 0o600 }); }
  }
}
function assertNoSecret(dir, dbUrl) {
  if (!existsSync(dir)) return; const variants = secretVariants(dbUrl);
  for (const name of readdirSync(dir)) {
    const path = join(dir, name); const info = statSync(path);
    if (info.isDirectory()) assertNoSecret(path, dbUrl);
    else if (info.isFile()) { const content = readFileSync(path, 'utf8'); for (const secret of variants) if (content.includes(secret)) throw new Error(`Credential redaction regression in ${path}`); if (/postgres(?:ql)?:\/\/[^\s'"`<>]+/i.test(content)) throw new Error(`Database URI redaction regression in ${path}`); }
  }
}
function selfTest() {
  const sentinel = 'SENTINEL_DB_PASSWORD_DO_NOT_LEAK';
  const fake = `postgresql://postgres.test:${sentinel}%40encoded@aws-1-ap-south-1.pooler.supabase.com:5432/postgres`;
  const sample = `failure: Command failed: psql ${fake}\npassword=${sentinel}@encoded`;
  const cleaned = redact(sample, fake);
  if (cleaned.includes(sentinel) || cleaned.includes(fake) || /postgres(?:ql)?:\/\/[^\s'"`<>]+/i.test(cleaned)) throw new Error('Credential redaction self-test failed');
  mkdirSync(outDir, { recursive: true }); const testPath = join(outDir, 'redaction-self-test.txt'); writeFileSync(testPath, sample, { mode: 0o600 }); sanitizeTree(outDir, fake); assertNoSecret(outDir, fake); console.log('PASS: certification credential redaction self-test');
}
function prepareIsolatedRunner() {
  let generated = readFileSync(sourceRunner, 'utf8');
  const fixedGst = "values(:'company',:'prefix','07AACCC0000A1Z5','New Delhi','approved','prepaid');";
  const uniqueGst = "values(:'company',:'prefix','07AACCC'||substr(md5(:'prefix'),1,4)||'A1Z5','New Delhi','approved','prepaid');";
  if (!generated.includes(fixedGst)) throw new Error('Certification runner GST fixture signature changed; refusing unsafe runtime rewrite');
  generated = generated.replace(fixedGst, uniqueGst);
  const orderColumns = 'insert into public.orders(id,company_id,status,order_number,sales_order_value,advance_required,advance_paid,payment_status,payment_cleared,final_invoice_url,order_origin)';
  const orderColumnsWithToken = 'insert into public.orders(id,company_id,status,order_number,sales_order_value,advance_required,advance_paid,payment_status,payment_cleared,final_invoice_url,order_origin,tracking_token)';
  const authorityValues = "(:'authority_order',:'company','submitted',:'prefix'||'-AUTH',100,30,30,'advance_paid',false,'https://example.invalid/invoice','LEGACY_ERP'),";
  const authorityValuesWithToken = "(:'authority_order',:'company','submitted',:'prefix'||'-AUTH',100,30,1000,'advance_paid',false,'https://example.invalid/invoice','LEGACY_ERP',md5(:'prefix'||'-AUTH')),";
  const cartonValues = "(:'carton_order',:'company','cleared_for_dispatch',:'prefix'||'-CARTON',100,0,100,'paid',true,'https://example.invalid/invoice','LEGACY_ERP');";
  const cartonValuesWithToken = "(:'carton_order',:'company','cleared_for_dispatch',:'prefix'||'-CARTON',100,0,100,'paid',true,'https://example.invalid/invoice','LEGACY_ERP',md5(:'prefix'||'-CARTON'));";
  for (const signature of [orderColumns, authorityValues, cartonValues]) if (!generated.includes(signature)) throw new Error('Certification runner order fixture signature changed; refusing unsafe runtime rewrite');
  generated = generated.replace(orderColumns, orderColumnsWithToken).replace(authorityValues, authorityValuesWithToken).replace(cartonValues, cartonValuesWithToken);
  const draftInsert = 'insert into public.sales_order_drafts(id,packet_id,extraction_request_key,status,company_id,company_name,readiness_overall_score,readiness_dimensions,original_whatsapp_text,created_by,updated_by)';
  const draftInsertWithPacket = `with cert_contact as (\n        insert into public.whatsapp_contacts(phone_number) values (substr(md5(:'draft'),1,20)) returning id\n      ), cert_packet as (\n        insert into public.whatsapp_message_packets(contact_id,stitched_content,first_message_at,last_message_at)\n        select id,'{}'::jsonb,now(),now() from cert_contact returning id\n      )\n      ${draftInsert}`;
  const draftValues = "values(:'draft',gen_random_uuid(),:'key','UNDER_REVIEW'";
  const draftValuesWithPacket = "values(:'draft',(select id from cert_packet),:'key','UNDER_REVIEW'";
  if (!generated.includes(draftInsert) || !generated.includes(draftValues)) throw new Error('Certification runner WA fixture signature changed; refusing unsafe runtime rewrite');
  generated = generated.split(draftInsert).join(draftInsertWithPacket).split(draftValues).join(draftValuesWithPacket);
  const badDraftInsert = 'insert into public.sales_order_drafts(id,packet_id,extraction_request_key,status,company_id,readiness_overall_score,readiness_dimensions,original_whatsapp_text)';
  const badDraftWithPacket = `with cert_contact as (insert into public.whatsapp_contacts(phone_number) values (substr(md5(:'draft'),1,20)) returning id),\n       cert_packet as (insert into public.whatsapp_message_packets(contact_id,stitched_content,first_message_at,last_message_at) select id,'{}'::jsonb,now(),now() from cert_contact returning id)\n       ${badDraftInsert}`;
  if (!generated.includes(badDraftInsert)) throw new Error('Certification runner invalid-WA fixture signature changed; refusing unsafe runtime rewrite');
  generated = generated.replace(badDraftInsert, badDraftWithPacket);
  writeFileSync(generatedRunner, generated, { mode: 0o600 });
}
if (process.argv.includes('--self-test')) { selfTest(); process.exit(0); }
const dbUrl = process.env.SUPABASE_DB_URL ?? '';
prepareIsolatedRunner();
const result = spawnSync(process.execPath, [generatedRunner], { env: process.env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
sanitizeTree(outDir, dbUrl); assertNoSecret(outDir, dbUrl);
if (result.stdout) process.stdout.write(redact(result.stdout, dbUrl));
if (result.stderr) process.stderr.write(redact(result.stderr, dbUrl));
if (result.error) process.stderr.write(`${redact(result.error.message, dbUrl)}\n`);
if (result.status !== 0) { console.error(`Step 1 staging certification failed with exit code ${result.status ?? 1}; credentials redacted.`); process.exit(result.status ?? 1); }
console.log('PASS: certification process-boundary credential redaction verified');
