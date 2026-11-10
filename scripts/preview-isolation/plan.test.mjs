import { readFileSync } from "node:fs";
import assert from "node:assert/strict";
import test from "node:test";
import {
  buildQuarantinePlan,
  PRODUCTION,
  quarantineSource,
  TARGET,
} from "./plan.mjs";
import { denyPreviewRequest } from "./handler.mjs";

const manifest = JSON.parse(
  readFileSync(new URL("./manifest.json", import.meta.url)),
);
const observed = () => ({
  project_ref: TARGET,
  parent_project_ref: PRODUCTION,
  is_default: false,
  preview_project_status: "ACTIVE_HEALTHY",
  active_cron: 0,
  queued_requests: 0,
  network_trigger_count: 0,
  functions: manifest.functions.map((f) => ({
    name: f.slug,
    id: f.id,
    version: f.version,
    ezbr_sha256: f.bundle_sha256,
    verify_jwt: f.verify_jwt,
  })),
});
const approval = {
  target_project: TARGET,
  quarantine_all_edge_functions: true,
  acknowledge_auth_and_ai_unavailable: true,
};

test("all 39 functions are covered, original JWT gates preserved, no provider or database code bundled", () => {
  const plan = buildQuarantinePlan(manifest, observed(), approval);
  assert.equal(plan.length, 39);
  for (const entry of plan) {
    assert.equal(entry.project_id, TARGET);
    assert.equal(
      entry.verify_jwt,
      manifest.functions.find((f) => f.slug === entry.name).verify_jwt,
    );
    for (const file of entry.files) {
      assert.doesNotMatch(
        file.content,
        /fetch\s*\(|createClient|\.rpc\(|\.from\(|authkey|service.role|req\.json|req\.headers/i,
      );
    }
    assert.match(entry.files[0].content, /from "\.\/handler\.mjs"/);
  }
});

test("production, default branch and wrong parent never produce deployment plans", () => {
  for (
    const override of [{ project_ref: PRODUCTION }, { is_default: true }, {
      parent_project_ref: TARGET,
    }]
  ) {
    assert.throws(() =>
      buildQuarantinePlan(manifest, { ...observed(), ...override }, approval)
    );
  }
  assert.throws(() =>
    buildQuarantinePlan(
      { ...manifest, target_project: PRODUCTION },
      observed(),
      approval,
    )
  );
});

test("neither caller credentials nor generic approval authorize total Preview quarantine", () => {
  for (
    const rejected of [
      undefined,
      {},
      { ...approval, target_project: PRODUCTION },
      { ...approval, quarantine_all_edge_functions: false },
      { ...approval, acknowledge_auth_and_ai_unavailable: false },
    ]
  ) {
    assert.throws(() => buildQuarantinePlan(manifest, observed(), rejected));
  }
});

test("new/removed/deployed/renamed functions and weakened JWT metadata fail the whole plan", () => {
  for (
    const mutate of [
      (o) => o.functions.pop(),
      (o) => o.functions.push({ name: "new-function" }),
      (o) => {
        o.functions[0].version++;
      },
      (o) => {
        o.functions[0].name = "renamed";
      },
      (o) => {
        o.functions[0].ezbr_sha256 = "0".repeat(64);
      },
      (o) => {
        o.functions[0].verify_jwt = !o.functions[0].verify_jwt;
      },
    ]
  ) {
    const o = observed();
    mutate(o);
    assert.throws(() => buildQuarantinePlan(manifest, o, approval));
  }
});

test("cron, database HTTP triggers, pending outbound work and unhealthy project block rollout", () => {
  for (
    const delta of [{ active_cron: 1 }, { queued_requests: 1 }, {
      network_trigger_count: 1,
    }, { preview_project_status: "COMING_UP" }]
  ) {
    assert.throws(() =>
      buildQuarantinePlan(manifest, { ...observed(), ...delta }, approval)
    );
  }
});

test("runtime source has exact project guard and never reads caller secrets, recipient, body or JWT", () => {
  const source = readFileSync(
    new URL("./handler.mjs", import.meta.url),
    "utf8",
  );
  assert.match(source, new RegExp(TARGET));
  assert.doesNotMatch(source, new RegExp(PRODUCTION));
  assert.match(source, /runtimeUrl !== EXPECTED_URL/);
  assert.match(source, /status: 403/);
  assert.match(source, /status: 503/);
  assert.match(source, /Cache-Control.*no-store/);
  assert.doesNotMatch(
    source,
    /request\.(?:headers|json|text|url)|Bearer|token|secret/i,
  );
  assert.match(
    quarantineSource(),
    /denyPreviewRequest\(request, Deno\.env\.get\("SUPABASE_URL"\)\)/,
  );
});

test("real handler denies all methods, direct paths and spoofed identities; OPTIONS is inert", async () => {
  for (
    const method of ["GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS"]
  ) {
    for (
      const path of [
        "/functions/v1/msg91-otp",
        "/functions/v1/whatsapp-webhook?hub.challenge=test",
        "/functions/v1/notify-event",
      ]
    ) {
      const request = new Request("https://attacker.invalid" + path, {
        method,
        headers: {
          authorization: "Bearer forged-service-role",
          "x-environment": "production",
          "x-supabase-url": "https://" + PRODUCTION + ".supabase.co",
        },
        ...(["POST", "PUT", "PATCH", "DELETE"].includes(method)
          ? { body: "{invalid-json-and-caller-otp}" }
          : {}),
      });
      const response = denyPreviewRequest(
        request,
        "https://" + TARGET + ".supabase.co",
      );
      assert.equal(response.status, method === "OPTIONS" ? 204 : 503);
      assert.equal(response.headers.get("Cache-Control"), "no-store");
      assert.doesNotMatch(
        await response.text(),
        /forged|invalid-json|attacker|tcxv/,
      );
      assert.equal(
        denyPreviewRequest(request, "https://" + PRODUCTION + ".supabase.co")
          .status,
        403,
      );
      assert.equal(denyPreviewRequest(request, undefined).status, 403);
    }
  }
});
