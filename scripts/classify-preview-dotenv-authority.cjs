#!/usr/bin/env node
'use strict';
// Read-only classifier. The production private key is supplied through stdin,
// never argv, Git logs, tracked files, child-process arguments or step outputs.
const fs = require('node:fs');
const crypto = require('node:crypto');
const cp = require('node:child_process');
function fail(message) {
  process.stderr.write('PREVIEW_DOTENV_AUTHORITY_CLASSIFICATION_UNAVAILABLE: ' + message + '\n');
  process.exit(1);
}
const privateKey = fs.readFileSync(0, 'utf8').trim();
if (!/^[a-f\d]{64}$/i.test(privateKey)) fail('unsupported private-key format');
let authoritativePublic;
try {
  const ecdh = crypto.createECDH('secp256k1');
  ecdh.setPrivateKey(Buffer.from(privateKey, 'hex'));
  authoritativePublic = ecdh.getPublicKey('hex', 'compressed').toLowerCase();
} catch (_) {
  fail('unable to derive public key');
}
function publicKeyFrom(text) {
  const line = text.split(/\r?\n/).find((s) => /^DOTENV_PUBLIC_KEY_PREVIEW=/.test(s));
  if (!line) return null;
  return line.slice(line.indexOf('=') + 1).trim().replace(/^["']|["']$/g, '').toLowerCase();
}
let currentText, mainText;
try {
  currentText = fs.readFileSync('supabase/.env.preview', 'utf8');
  mainText = cp.execFileSync('git', ['show', 'origin/main:supabase/.env.preview'], {
    encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'], timeout: 10000
  });
} catch (_) {
  fail('unable to read current PR and main ciphertext metadata');
}
const currentPublic = publicKeyFrom(currentText);
const mainPublic = publicKeyFrom(mainText);
if (!currentPublic || !mainPublic) fail('missing public-key metadata');
process.stdout.write('PRODUCTION_DOTENV_KEY_MATCHES_PR_PUBLIC_KEY=' + (authoritativePublic === currentPublic) + '\n');
process.stdout.write('PRODUCTION_DOTENV_KEY_MATCHES_MAIN_PUBLIC_KEY=' + (authoritativePublic === mainPublic) + '\n');
// Public-key agreement is necessary, but is NOT ciphertext decryption proof.
