# Core #519–#522: evidence and remaining closure gates

No protected merge, production configuration change or production migration is authorized by this document. No issue is closed merely because its source tests pass.

## Verified current state

- #519: source head 5256376a4d39e00ebd894d7fafa5d27cc673886b remains open/unmerged, with successful required checks and existing human approval. Address/transporter code needs no speculative rewrite. Compatibility, device acceptance, provider isolation and protected production rollout remain gates.
- #520: existing source branch 67d23b4de3dea0b79e4de8e00953fad8eff08f20 covered only selected Core provider calls. The real Deno test initially failed because it compared the handler's guard against an earlier helper declaration's audit write. The assertion now checks the handler-local audit write; all six Deno gate tests pass. This correction does not assert coverage of all 39 deployed functions.
- #521 is the parent legacy MSG91 security issue; #522 contains its code fix. Both remain open until their release criteria pass.
- #522: c349a4b5b66dc58fcc04db32ac239779a25b1df8, draft/unmerged. All executed CI checks and final-head Greptile review pass. A fresh final-head CodeRabbit review is requested. Preview jiocprripcelwujsgwdq now runs msg91-otp v98 and bridge v12, all returned files matched to that commit. Real-token and Android acceptance are still outstanding.
- MSG91 owner-approved settings were saved and confirmed after reload: Invisible OTP disabled; real-number demo bypass removed. No replacement bypass was added, and no real SMS delivery is claimed.

## Fresh #519 Preview isolation census

Target: stkvyotdkysieuvpuues (existing paid Preview; no new resource).

All 39 deployed function bundles were read, including their relative dependencies. Original deployment IDs, versions, JWT flags and bundle hashes are pinned in scripts/preview-isolation/manifest.json. Exact retrieved source/metadata snapshots are retained under docs/evidence/preview519-edge-baseline/ for rollback preparation. These are historical evidence, not active application source or deployment instructions.

Database read-only results: active cron=0; pg_net pending queue=0; no user-defined network triggers. Only the two owner-only scheduler functions reference net.http_post; neither anon, authenticated nor service_role can execute them. Neither configured scheduler consumer URL secret is present. Generic net HTTP functions have broad PostgreSQL execution privileges, but no remote/public RPC route to them has been certified; this document does not equate role grants with Data API exposure.

## Concrete reversible isolation option — NOT APPLIED

The source-only planner replaces every Edge entrypoint on this one Preview with an opaque no-network denial handler. It preserves each existing gateway JWT flag, rejects production/default/wrong-parent targets, requires an exact 39-function version/hash census, checks database quietness, and requires explicit acknowledgement that Preview Auth/AI/application Edge functions become unavailable. The handler has no provider SDK, database client, request-body parsing, token inspection, queue mutation or network operation. OPTIONS returns inert 204; all business requests return 503. Wrong runtime project returns 403.

This is **total temporary quarantine**, not a working login environment, a production patch, or a completed replacement for all per-call-site guards. It enables a safe boundary for separately reviewed database/PostgREST-only testing. Real MSG91 login stays on the separate #522 authentication Preview; combined final Android acceptance must later use an approved environment with reviewed, narrowly permitted auth endpoints. Do not silently switch APK backends or call the quarantined Preview a complete Appverse.

Seven Node tests exercise the actual deny handler, hostile methods/paths/headers, wrong project, no credentials/body leakage, preservation of JWT metadata, changed-function census denial, cron/queue/trigger denial and explicit acknowledgement requirements. Six Deno tests exercise the existing selective provider gate. These are source/runtime-unit tests, not hosted rollout evidence or an independent review.

Before rollout: independent source review, explicit owner approval for the availability impact, fresh baseline comparison, complete source snapshot availability and an approved rollback plan. No new paid branch or PR was opened for this option. The source-only branch workflow has no deployment or provider credentials and performs no network-provider calls.

## Release prerequisites that remain real

1. Select and approve isolation approach; deploy only to the approved disposable Preview and independently verify all direct/indirect negative paths. Retain zero active cron and zero queued sends.
2. Inventory installed legacy address writers before #519 Stage B revokes direct writes. The old APK is production-bound and is not a disposable mutation fixture.
3. Actual MSG91 widget -> provider verification -> Core bridge -> correct Auth UUID -> company/role -> Buyer dashboard acceptance, including invalid/expired OTP, new approved account, re-login, legacy recovery, duplicates and concurrent requests.
4. The current Android build workflow only permits protected main. A pre-merge internal build needs a separately reviewed build route or an explicit release-sequencing decision; do not weaken the existing guard to force an APK out.
5. Prevent future reserved-alias signup squatting without breaking other Appverse registration consumers. Production inventory currently reports six internal aliases, all with confirmed phones; that is not prevention of future attacks.
6. Independent final-head reviews, human approval and separately approved production migration/deployment. No billing upgrade, custom sender/DLT configuration, protected merge, production secret/configuration or production data was changed by this work.

Decision: **NOT CLOSED.** Engineering evidence is preserved; the availability and live/device gates must not be relabelled as complete.
