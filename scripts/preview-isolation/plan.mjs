import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

export const TARGET = "stkvyotdkysieuvpuues";
export const PRODUCTION = "tcxvcatsqqertcnycuop";

// This source has no imports, client, credentials, queue access or network capability.
// It is an optional, deliberately total quarantine of an existing disposable Preview.
// It is never a replacement for production application source.
export function quarantineSource() {
  return 'import { denyPreviewRequest } from "./handler.mjs";\n' +
    'Deno.serve((request: Request) => denyPreviewRequest(request, Deno.env.get("SUPABASE_URL")));\n';
}

function assert(condition, message) {
  if (!condition) throw new Error(message);
}

/** Pure planner. It never deploys, contacts a provider, opens a PR or creates a branch. */
export function buildQuarantinePlan(manifest, observed, approval) {
  assert(manifest.schema_version === 1, "unsupported_manifest");
  assert(manifest.mode === "quarantine-all-edge-functions", "unsupported_mode");
  assert(
    manifest.target_project === TARGET && TARGET !== PRODUCTION,
    "unsafe_target",
  );
  assert(manifest.parent_project === PRODUCTION, "wrong_parent");
  assert(
    observed.project_ref === TARGET &&
      observed.parent_project_ref === PRODUCTION &&
      observed.is_default === false,
    "observed_target_mismatch",
  );
  assert(
    observed.preview_project_status === "ACTIVE_HEALTHY",
    "preview_not_healthy",
  );
  assert(
    approval?.target_project === TARGET &&
      approval?.quarantine_all_edge_functions === true,
    "explicit_quarantine_approval_required",
  );
  assert(
    approval?.acknowledge_auth_and_ai_unavailable === true,
    "quarantine_is_not_login_uat",
  );
  assert(
    observed.active_cron === 0 && observed.queued_requests === 0 &&
      observed.network_trigger_count === 0,
    "database_network_not_quiet",
  );
  assert(
    Array.isArray(manifest.functions) && manifest.functions.length === 39,
    "incomplete_baseline",
  );
  assert(
    Array.isArray(observed.functions) &&
      observed.functions.length === manifest.functions.length,
    "function_census_changed",
  );
  const names = new Set();
  for (const baseline of manifest.functions) {
    assert(
      /^[a-z][a-z0-9-]*$/.test(baseline.slug) && !names.has(baseline.slug),
      "invalid_or_duplicate_slug",
    );
    names.add(baseline.slug);
    const live = observed.functions.find((f) => f.name === baseline.slug);
    assert(
      live && live.id === baseline.id && live.version === baseline.version &&
        live.ezbr_sha256 === baseline.bundle_sha256 &&
        live.verify_jwt === baseline.verify_jwt,
      "function_baseline_drift:" + baseline.slug,
    );
    assert(
      typeof baseline.verify_jwt === "boolean" &&
        /^[a-f0-9]{64}$/.test(baseline.bundle_sha256),
      "invalid_baseline",
    );
  }
  return manifest.functions.map((f) => ({
    project_id: TARGET,
    name: f.slug,
    verify_jwt: f.verify_jwt,
    entrypoint_path: "index.ts",
    files: [{ name: "index.ts", content: quarantineSource() }, {
      name: "handler.mjs",
      content: readFileSync(new URL("./handler.mjs", import.meta.url), "utf8"),
    }],
    before: { id: f.id, version: f.version, bundle_sha256: f.bundle_sha256 },
  }));
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const [manifestPath, observedPath, approvalPath] = process.argv.slice(2);
  if (!manifestPath || !observedPath || !approvalPath) {
    throw new Error(
      "Usage: node plan.mjs manifest.json observed.json approval.json (dry-run only)",
    );
  }
  const read = (p) => JSON.parse(readFileSync(p, "utf8"));
  const plan = buildQuarantinePlan(
    read(manifestPath),
    read(observedPath),
    read(approvalPath),
  );
  process.stdout.write(
    JSON.stringify(
      { dry_run: true, deployed: false, function_count: plan.length, plan },
      null,
      2,
    ) + "\n",
  );
}
