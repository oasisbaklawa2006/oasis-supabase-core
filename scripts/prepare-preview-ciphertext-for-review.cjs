#!/usr/bin/env node
'use strict';
// REVIEW ONLY. Uses an existing 32-byte dotenvx private key to prepare encrypted
// preview ciphertext; never creates/changes an authority, deploys, or pushes Git.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const REQUIRED_BRANCH = 'refs/heads/recovery/preview-dotenv-authority-20261012';
const PRODUCTION_REF = 'tcxvcatsqqertcnycuop';
const VERSION = '1.44.1';

function fail(message) { throw new Error(message); }
function cli(args, env) {
  const proc = spawnSync('npx', ['--yes', '@dotenvx/dotenvx@' + VERSION, ...args], {
    env, encoding: 'utf8', timeout: 150000, maxBuffer: 1024 * 1024,
    stdio: ['ignore', 'pipe', 'pipe']
  });
  // Never print stdout/stderr from failed crypto commands (possible key material).
  if (proc.error || proc.status !== 0) fail('dotenvx ' + args[0] + ' failed (status ' + String(proc.status ?? 'unavailable') + '; output withheld)');
  return proc.stdout.replace(/\r?\n$/, '');
}
function run() {
  const args = process.argv.slice(2);
  if (args.length !== 4 || args[0] !== '--key-file' || args[2] !== '--output')
    fail('usage: node script --key-file PRIVATE_KEY_FILE --output ENCRYPTED_FILE');
  if (process.env.GITHUB_ACTIONS === 'true' && process.env.GITHUB_REF !== REQUIRED_BRANCH)
    fail('preparation must run only from the designated review branch');
  if (process.env.PRODUCTION_PROJECT_REF !== PRODUCTION_REF)
    fail('production project ref mismatch');
  const gemini = process.env.GEMINI_API_KEY;
  const cert = process.env.WA_STAGE1B_CERT_SECRET;
  if (!gemini || !cert || gemini === cert) fail('missing or non-independent source secrets');
  const key = fs.readFileSync(args[1], 'utf8').trim();
  if (!/^[a-f\d]{64}$/i.test(key)) fail('private key unavailable/invalid; do not rotate automatically');
  const ecdh = crypto.createECDH('secp256k1');
  ecdh.setPrivateKey(Buffer.from(key, 'hex'));
  const publicKey = ecdh.getPublicKey('hex', 'compressed').toLowerCase();
  const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'preview-authority-review-'));
  fs.chmodSync(tmp, 0o700);
  try {
    const keysFile = path.join(tmp, '.env.keys');
    const envFile = path.join(tmp, '.env.preview');
    fs.writeFileSync(keysFile, 'DOTENV_PRIVATE_KEY_PREVIEW="' + key + '"\n', { mode: 0o600, flag: 'wx' });
    // These plaintext values exist in this temporary directory only, never
    // in Git, workflow outputs, logs or upload artifacts.
    fs.writeFileSync(envFile,
      'DOTENV_PUBLIC_KEY_PREVIEW="' + publicKey + '"\n' +
      'GEMINI_API_KEY=' + JSON.stringify(gemini) + '\n' +
      'WA_STAGE1B_CERT_SECRET=' + JSON.stringify(cert) + '\n',
      { mode: 0o600, flag: 'wx' });
    const env = { ...process.env };
    delete env.GEMINI_API_KEY;
    delete env.WA_STAGE1B_CERT_SECRET;
    delete env.PREVIEW_DOTENV_PRIVATE_KEY;
    delete env.DOTENV_PRIVATE_KEY_PREVIEW;
    cli(['encrypt', '-f', envFile, '-fk', keysFile, '--no-native'], env);
    const encrypted = fs.readFileSync(envFile, 'utf8');
    if (fs.readFileSync(keysFile, 'utf8').trim() !== 'DOTENV_PRIVATE_KEY_PREVIEW="' + key + '"')
      fail('dotenvx changed the existing authority; refusing generated key');
    const lines = encrypted.split(/\r?\n/);
    if (!lines.includes('DOTENV_PUBLIC_KEY_PREVIEW="' + publicKey + '"'))
      fail('output public key does not match existing authority');
    for (const name of ['GEMINI_API_KEY', 'WA_STAGE1B_CERT_SECRET']) {
      if (!lines.some(s => s.startsWith(name + '=') && s.includes('encrypted:')))
        fail(name + ' is not encrypted');
    }
    if (cli(['get', 'GEMINI_API_KEY', '-f', envFile, '-fk', keysFile, '--strict'], env) !== gemini)
      fail('Gemini encrypted round-trip failed');
    if (cli(['get', 'WA_STAGE1B_CERT_SECRET', '-f', envFile, '-fk', keysFile, '--strict'], env) !== cert)
      fail('WA certification encrypted round-trip failed');
    const output = path.resolve(args[3]);
    fs.mkdirSync(path.dirname(output), { recursive: true, mode: 0o700 });
    fs.writeFileSync(output, encrypted, { mode: 0o600, flag: 'wx' });
    console.log('Encrypted candidate verified using existing authority. No key update, Git write, or deployment.');
  } finally {
    fs.rmSync(tmp, { recursive: true, force: true });
  }
}
try { run(); } catch (err) {
  console.error('PREVIEW_REENCRYPT_PREPARATION_FAILED: ' + err.message);
  process.exitCode = 1;
}
