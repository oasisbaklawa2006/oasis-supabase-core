import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { createHash } from "node:crypto";
import {
  appendFileSync, copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync,
  readdirSync, rmSync, symlinkSync, writeFileSync,
} from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { test } from "node:test";
import { fileURLToPath } from "node:url";

import { allowQaBuyerPreflight } from "../genie-qa/qa-gateway-guard.mjs";

const qaRef = "skhpmltfjgqitntkmclb";
const phones = ["916000000001", "917000000002", "918000000003", "919000000004",
  "916000000005", "917000000006", "918000000007", "919000000008"];
const [a, b, c] = phones;
const env = {
  SUPABASE_URL: `https://${qaRef}.supabase.co`,
  QA_MSG91_PROVIDER_ENABLED: "true",
  QA_MSG91_PROVIDER_AUTH_KEY: "synthetic-test-key",
  QA_MSG91_TEST_PHONE_ALLOWLIST: [a, b].join(","),
};
const body = { mode: "preflight", channel: "mobile", identifier: a };
const run = (overrides = {}, request = body) => {
  const values = { ...env, ...overrides };
  return allowQaBuyerPreflight(name => values[name], request);
};

test("accepts every exact mobile entry at the minimum and maximum allowlist sizes", () => {
  for (const list of [phones.slice(0, 2), phones]) {
    for (const identifier of list) {
      assert.equal(run({ QA_MSG91_TEST_PHONE_ALLOWLIST: list.join(",") }, { ...body, identifier }), true);
    }
  }
});

test("denies requests other than an exact allowlisted mobile preflight", () => {
  const requests = {
    unlisted: { ...body, identifier: c },
    international: { ...body, identifier: "+" + a },
    local: { ...body, identifier: a.slice(2) },
    "trailing whitespace": { ...body, identifier: a + " " },
    email: { ...body, channel: "email" },
    send: { ...body, mode: "send" },
    "missing mode": { channel: "mobile", identifier: a },
    "missing channel": { mode: "preflight", identifier: a },
    "missing identifier": { mode: "preflight", channel: "mobile" },
    numeric: { ...body, identifier: Number(a) },
    "null body": null,
  };
  for (const [label, request] of Object.entries(requests)) {
    assert.equal(run({}, request), false, label);
  }
});

test("requires the exact QA project and activation flag, and only the dedicated key", () => {
  const cases = {
    "wrong project": { SUPABASE_URL: "https://other.supabase.co" },
    "changed URL": { SUPABASE_URL: env.SUPABASE_URL + "/" },
    "missing project": { SUPABASE_URL: undefined },
    "missing activation": { QA_MSG91_PROVIDER_ENABLED: undefined },
    "disabled activation": { QA_MSG91_PROVIDER_ENABLED: "false" },
    "noncanonical activation": { QA_MSG91_PROVIDER_ENABLED: "TRUE" },
    "missing dedicated key": { QA_MSG91_PROVIDER_AUTH_KEY: undefined },
    "empty dedicated key": { QA_MSG91_PROVIDER_AUTH_KEY: "" },
    "whitespace dedicated key": { QA_MSG91_PROVIDER_AUTH_KEY: " " },
    "padded dedicated key": { QA_MSG91_PROVIDER_AUTH_KEY: " test " },
    "legacy key": { MSG91_AUTH_KEY: "synthetic-legacy-key" },
    "AI key": { OPENAI_API_KEY: "synthetic-ai-key" },
  };
  for (const [label, overrides] of Object.entries(cases)) {
    assert.equal(run(overrides), false, label);
  }
});

test("rejects the entire allowlist if even one entry is invalid", () => {
  const cases = {
    missing: undefined,
    "not a string": [a, b],
    empty: "",
    "below minimum": a,
    "above maximum": [...phones, "919000000009"].join(","),
    duplicate: [a, b, a].join(","),
    "empty entry": a + "," + b + ",",
    "whitespace in another entry": a + ", " + b,
    "wrong country code": a + ",927000000002",
    "invalid mobile prefix": a + ",915000000002",
    "too few digits": a + "," + b.slice(0, -1),
    "too many digits": a + "," + b + "0",
  };
  for (const [label, value] of Object.entries(cases)) {
    assert.equal(run({ QA_MSG91_TEST_PHONE_ALLOWLIST: value }), false, label);
  }
});

test("fails closed when reading the environment throws", () => {
  assert.equal(allowQaBuyerPreflight(name => {
    if (name === "QA_MSG91_TEST_PHONE_ALLOWLIST") throw new Error("cannot read allowlist");
    return env[name];
  }, body), false);
});

const qaScripts = fileURLToPath(new URL("../genie-qa/", import.meta.url));
const stageName = "stage_buyer_login_gateway.sh";
const snapshotName = "central-buyer-login-gateway.snapshot.txt";
const releaseName = "release_buyer_login_gateway.sh";
const gateway = "buyer-login-gateway";

function scratch(t) {
  const dir = mkdtempSync(join(tmpdir(), "genie-qa-gateway-test-"));
  t.after(() => rmSync(dir, { recursive: true, force: true }));
  return dir;
}

function bash(script, args, options = {}) {
  const result = spawnSync("bash", [script, ...args], {
    encoding: "utf8", timeout: 5000, ...options,
  });
  assert.ifError(result.error);
  assert.equal(result.signal, null);
  return result;
}

test("stages only the QA gateway and attests its source closure", t => {
  const output = join(scratch(t), "candidate with spaces");
  const result = bash(join(qaScripts, stageName), [qaRef, output]);
  assert.equal(result.status, 0, result.stderr);
  const functions = join(output, "supabase", "functions");
  assert.deepEqual(readdirSync(functions), [gateway]);
  assert.match(readFileSync(join(output, "supabase", "config.toml"), "utf8"),
    /^project_id = "skhpmltfjgqitntkmclb"\s*$/);

  const manifest = JSON.parse(readFileSync(join(output, "gateway-source.json"), "utf8"));
  assert.equal(manifest.function, gateway);
  assert.equal(manifest.entrypoint, `${gateway}/index.ts`);
  assert.equal(manifest.fileCount, 2);
  assert.deepEqual(manifest.files.map(file => file.path), [
    `${gateway}/index.ts`, `${gateway}/qa-gateway-guard.mjs`,
  ]);
  for (const file of manifest.files) {
    const content = readFileSync(join(functions, file.path));
    assert.equal(file.sha256, createHash("sha256").update(content).digest("hex"), file.path);
    assert.equal(file.size, content.length, file.path);
  }

  assert.deepEqual(readFileSync(join(functions, gateway, "qa-gateway-guard.mjs")),
    readFileSync(join(qaScripts, "qa-gateway-guard.mjs")));

  const source = readFileSync(join(functions, manifest.entrypoint), "utf8");
  const guardImport = /^import \{ allowQaBuyerPreflight \} from "\.\/qa-gateway-guard\.mjs";\n/m;
  const guardCheck = /^    if \(!allowQaBuyerPreflight.*Deno\.env\.get\(name\), body\)\) return json\(\{ ok: true, \.\.\.result\("ambiguous", "mobile"\) \}\);\n/m;
  assert.match(source, guardImport);
  assert.match(source, guardCheck);
  assert.ok(source.search(guardCheck) < source.indexOf("if (await isRateLimited("),
    "the guard must return before the rate limiter and eligibility lookup");
  const original = readFileSync(join(qaScripts, snapshotName), "utf8");
  const expected = original
    .replace(/function normalizeEmail\([\s\S]*?(?=function normalizePhone\()/, "")
    .replace(/async function classifyEmail\([\s\S]*?(?=async function classifyMobile\()/, "")
    .replace('    const eligibility = channel === "email"\n      ? await classifyEmail(identifier)\n      : await classifyMobile(identifier);',
      '    const eligibility = await classifyMobile(identifier);');
  assert.equal(source.replace(guardImport, "").replace(guardCheck, ""), expected,
    "only the QA guard and removal of email-only paths may change the snapshot");
  assert.doesNotMatch(source, /classifyEmail|normalizeEmail|\.ilike\("email"|\.ilike\("contact_email"/);
  assert.match(source, /const eligibility = await classifyMobile\(identifier\);/);
});

test("staging rejects the wrong target and preserves occupied output paths", t => {
  const dir = scratch(t);
  const script = join(qaScripts, stageName);
  const fresh = join(dir, "fresh");
  const existing = join(dir, "existing");
  const link = join(dir, "dangling");
  mkdirSync(existing);
  writeFileSync(join(existing, "keep"), "original content");
  symlinkSync(fresh, link);

  for (const args of [["wrong-project", fresh], [qaRef, existing], [qaRef, link], [qaRef]]) {
    const result = bash(script, args);
    assert.equal(result.status, 1, args.join(" "));
  }
  assert.equal(existsSync(fresh), false);
  assert.deepEqual(readdirSync(existing), ["keep"]);
  assert.equal(readFileSync(join(existing, "keep"), "utf8"), "original content");
});

test("staging rejects a modified snapshot before creating output", t => {
  const dir = scratch(t);
  const scripts = join(dir, "scripts", "genie-qa");
  mkdirSync(scripts, { recursive: true });
  copyFileSync(join(qaScripts, stageName), join(scripts, stageName));
  copyFileSync(join(qaScripts, snapshotName), join(scripts, snapshotName));
  appendFileSync(join(scripts, snapshotName), "\n// modified test fixture\n");

  const output = join(dir, "candidate");
  assert.equal(bash(join(scripts, stageName), [qaRef, output]).status, 1);
  assert.equal(existsSync(output), false);
});

test("release fails closed on dispatch scope, authorization, and missing local evidence", t => {
  const dir = scratch(t);
  const bin = join(dir, "bin");
  mkdirSync(bin);
  // Start Bash with its normal executable lookup, then restrict the script PATH
  // to dirname so GitHub, Supabase, and database commands cannot run.
  const dirname = spawnSync("bash", ["-c", "command -v dirname"], { encoding: "utf8" });
  assert.equal(dirname.status, 0, dirname.stderr);
  symlinkSync(dirname.stdout.trim(), join(bin, "dirname"));

  const sha = "a".repeat(40);
  const inputs = {
    PATH: process.env.PATH,
    GATE_TEST_PATH: bin,
    RUNNER_TEMP: dir,
    GITHUB_REPOSITORY: "oasisbaklawa2006/oasis-supabase-core",
    GITHUB_REF: "refs/heads/main",
    GITHUB_EVENT_NAME: "workflow_dispatch",
    EXPECTED_SHA: sha,
    GITHUB_SHA: sha,
    QA_MODE: "deploy",
    QA_CHANGE_REFERENCE: "Core#495/Buyer#64;QA-EDGE-APPROVAL=test-ticket",
    QA_APPROVAL: "AUTHORIZE-GENIE-QA-BUYER-LOGIN-GATEWAY",
    SUPABASE_ACCESS_TOKEN: "synthetic-test-token",
    GH_TOKEN: "synthetic-test-token",
  };
  const cases = [
    [{ GITHUB_REPOSITORY: "example/fork" }, "deploy", "scope"],
    [{ GITHUB_REF: "refs/heads/topic" }, "deploy", "scope"],
    [{ GITHUB_EVENT_NAME: "pull_request" }, "deploy", "scope"],
    [{ EXPECTED_SHA: "aaa", GITHUB_SHA: "aaa" }, "deploy", "scope"],
    [{ GITHUB_SHA: "b".repeat(40) }, "deploy", "scope"],
    [{ QA_MODE: "invalid" }, "deploy", "scope"],
    [{ QA_CHANGE_REFERENCE: "Core#495/Buyer#64;QA-EDGE-APPROVAL=short" }, "deploy", "scope"],
    [{ SUPABASE_ACCESS_TOKEN: "" }, "deploy", "scope"],
    [{ GH_TOKEN: "" }, "deploy", "scope"],
    [{ QA_APPROVAL: "" }, "deploy", "authorization"],
    [{ QA_MODE: "preflight" }, "capture", "authorization"],
    [{}, "deploy", "missing_preflight"],
    [{ QA_MODE: "preflight", QA_APPROVAL: "" }, "invalid", "invocation"],
  ];
  const expectDenial = (overrides, action, denial) => {
    const result = bash("-c", [
      'export PATH="$GATE_TEST_PATH"; source "$0" "$@"',
      join(qaScripts, releaseName), action,
    ], { env: { ...inputs, ...overrides } });
    assert.equal(result.status, 1, result.stderr);
    assert.equal(result.stderr.trim(), `GENIE_QA_GATEWAY_DENIED: ${denial}`,
      JSON.stringify([overrides, action]));
    assert.equal(result.stdout, "");
  };
  for (const args of cases) expectDenial(...args);
  const work = join(dir, "genie-qa-buyer-gateway");
  assert.equal(existsSync(work), false);

  mkdirSync(join(work, "evidence"), { recursive: true });
  expectDenial({ QA_MODE: "preflight", QA_APPROVAL: "" }, "capture", "workspace");
  expectDenial({ QA_MODE: "preflight", QA_APPROVAL: "", ROLLBACK_ARTIFACT_ID: "42" },
    "deploy", "approval");
  expectDenial({}, "deploy", "approval");
  expectDenial({ ROLLBACK_ARTIFACT_ID: "not-numeric" }, "deploy", "approval");
  assert.deepEqual(readdirSync(work), ["evidence"]);
});

test("failure inventory exports only validated metadata, never raw response fields", t => {
  const dir = scratch(t);
  const input = join(dir, "raw.json"), output = join(dir, "safe.json");
  const row = {slug: gateway, status: "ACTIVE", version: 1, verify_jwt: false,
    ezbr_sha256: "a".repeat(64), id: "a6150000-0000-4000-8000-000000000001"};
  const helper = join(qaScripts, "sanitize_gateway_failure_inventory.py");
  const invoke = () => spawnSync("python3", [helper, input, output], {encoding:"utf8"});
  writeFileSync(input, JSON.stringify([{...row, access_token:"not-for-export", logs:"not-for-export"}]));
  assert.equal(invoke().status, 0);
  assert.deepEqual(JSON.parse(readFileSync(output,"utf8")), [row]);
  rmSync(output);
  for(const bad of [[{...row,version:"1"}],[{...row,ezbr_sha256:"secret"}],[{...row,slug:"other"}],[row,row]]) {
    writeFileSync(input,JSON.stringify(bad));
    const result=invoke();
    assert.equal(result.status,1);
    assert.equal(existsSync(output),false);
    assert.equal(result.stderr.trim(),"QA_GATEWAY_FAILURE_INVENTORY_UNAVAILABLE");
  }
});

test("protected workflow collects only sanitized failure evidence after deployment attempt", () => {
  const script=readFileSync(join(qaScripts, releaseName),"utf8");
  const workflow=readFileSync(fileURLToPath(new URL("../../.github/workflows/genie-qa-buyer-login-gateway-release.yml",import.meta.url)),"utf8");
  assert.match(script,/trap 'capture_failure "\$\?"' EXIT/);
  assert.ok(script.indexOf("trap 'capture_failure") < script.indexOf("supabase functions deploy buyer-login-gateway"));
  assert.match(script,/sanitize_gateway_failure_inventory\.py/);
  assert.match(workflow,/if: inputs\.mode == 'deploy' && failure\(\)/);
  assert.match(workflow,/genie-qa-buyer-gateway\/failure-evidence\//);
  assert.doesNotMatch(workflow,/path:.*(?:deploy\.log|download\.log|secrets\.json|failure-inventory-raw)/);
});
