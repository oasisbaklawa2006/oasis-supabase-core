# Studio AI-copy — isolated QA, inert source and protected UAT sequence

## Source-only release evidence preparation (23 November 2026)

Post-merge read-only preflight run `45062936271`, attempt 2, job
`137340881828`, passed at Core `350add39eee91830de6ac573ed920aaee71e0b91`.
Owner authorization for a shared-QA Studio slot and confirmation that other
Supabase writers are paused are recorded in Core #495 / Studio #240. These are
operational confirmations, not proof of a provider-enforced exclusive lock.

The protected `genie-qa-bootstrap` environment now has a separate
`STUDIO_QA_DEPLOY_TOKEN` secret; its presence was verified without reading its
value. `SUPABASE_ACCESS_TOKEN` remains the read-only preflight credential.
Secret presence alone does not prove its permission scope or token validity.
No workflow in this preparation consumes the deployment credential or performs
Edge, Auth, schema, secret or Production writes. The external-writer hold below
remains mandatory. In particular, a source-only PR is not deployment approval.

`scripts/studio-qa/verify_qa_bundle.py` prepares the offline evidence gate for
a future independently reviewed release runner. The runner must authenticate to
the pinned QA project, capture authoritative per-function metadata immediately
before and after a fresh download, and supply exactly the downloaded two-file
functions tree. The guard never downloads or executes that source. It rebuilds
the independently pinned inert candidate in a temporary directory, requires
byte-for-byte parity for both files, rejects missing/extra/symlinked files and
requires ACTIVE, explicit JWT verification, positive integer version, function
ID and bundle digest. A changed ID/version/digest during capture fails closed.
Evidence reads walk every parent through no-follow directory descriptors, open
leaf files without following symlinks, verify regular-file type and size with
`fstat`, and read from that same descriptor. Nonblocking opens reject FIFOs
without hanging. Unsupported secure-open platforms fail closed. These reads
attest the opened snapshot; they cannot freeze a concurrently modified tree.
It emits only selected sanitized metadata and per-file SHA-256 fingerprints.

Example for a future protected runner, using private temporary paths:

```sh
python3 -I scripts/studio-qa/verify_qa_bundle.py \
  --project-ref skhpmltfjgqitntkmclb \
  --functions-root "$REMOTE_SOURCE/supabase/functions" \
  --before "$PRIVATE_EVIDENCE/metadata-before.json" \
  --after "$PRIVATE_EVIDENCE/metadata-after.json"
```

This gate does **not** attest which endpoint supplied its input files, acquire
or verify an exclusive-writer lease, prevent Dashboard/API races, certify
runtime authorization, or authorize function removal. Those duties remain with
the future protected runner and independent release review. Its output explicitly
reports `exclusive_writer_verified=false` and
`authenticated_uat_executed=false`; no standalone guard PASS clears a release
gate. An interrupted or mismatched deployment must remain uncertified and be
reconciled before retry or cleanup. Before/after metadata consistency is a
capture-integrity check, not an external-writer lock.

Remaining release dependencies: independently verified external-writer control;
separately CODEOWNER-reviewed named-function QA deployment and cleanup workflow;
verified QA-only deployment credential scope; fresh protected preflight and
environment approval; disposable Auth/Studio fixture provisioning and 503/401/401
tests. Production deployment and paid activation remain separate gates.

**As of 22 November 2026: SOURCE-ONLY READ-ONLY PREPARATION; NO QA WRITE OR DEPLOYMENT.**

The billable Dashboard Preview `sefkuceukuulfgliaruw` was deleted after historical migration bootstrap failed (Core #495). Repeating that method is prohibited. The existing independently governed `oasis-genie-qa` project `skhpmltfjgqitntkmclb` has 516 canonical migrations, 392 public tables, one required WhatsApp system principal, both Studio authorization RPCs, zero outbound database extensions, and zero Edge Functions at the read-only checkpoint. This is shared QA infrastructure, **not an exclusive Studio lease**.

## Reviewed source boundary

`scripts/studio-qa/build_inert_copy.py` renders an **ephemeral** two-file QA closure from reviewed Core main. It preserves the entire original authentication/Studio permission/request-validation prefix, except for replacing the Origin configuration with a fixed synthetic `https://studio-qa.oasis.invalid` test header. It cuts off everything after `const apiKey = Deno.env.get("OPENAI_API_KEY");` and replaces the entire provider path with deterministic HTTP 503. It refuses source drift, duplicate expected anchors, unexpected early `fetch()`, or missing scoped `ai_studio.ai.use` check. The shared helper is copied byte-for-byte. The generated QA bundle has **no direct fetch or provider credential reference**. This output must **never** be merged into production source or released to Production.

## Protected read-only preflight only

The workflow `.github/workflows/studio-ai-copy-qa-preflight.yml` is manual `workflow_dispatch` on exact protected Core main, environment `genie-qa-bootstrap`, expected SHA and a structured `Core#495/Studio#240;QA-PREFLIGHT=...` justification. It checks:
- reviewed source and negative security regressions, canonical candidate file closure and JWT mode;
- QA-only direct Postgres/TLS with no secret exposure, exactly 516 expected applied schema versions and no-eject canonical no-egress state;
- no QA synthetic staff, a single untouched preexisting system service account, no sessions or refresh tokens;
- QA-only Edge Management API list empty (to avoid stealing Genie #585 environment);
- complete QA secret inventory available, **no non-platform custom secrets**, no unverified provider credentials;
- immutable current `main` before and after inspection.

The workflow never creates a user, uploads an Edge Function, sets secrets, applies SQL, invokes a provider or contacts customers. No source artifact is published; the only retained artifact is the sanitized offline candidate manifest.

## Release blocker and future separately approved steps

**Do not add a deploy step by hand to the currently reviewed workflow.** Genie QA #585's protected deploy job deliberately hard-stops with `GENIE_QA_EDGE_EXCLUSIVE_WRITER_HOLD`. GitHub concurrency does not control Dashboard/API writers; neither a zero-Edge count nor single GitHub environment approval gives an exclusive writer lock. Studio and Genie workflows also conflict over the shared QA zero-function invariant. A separate CODEOWNER-reviewed PR, owner scope/lease approval, independent protected environment reviewer and verified external-writer control must govern any **named-function QA-only deployment**, with before/after QA function list, source manifest and JWT, and an approved rollback/removal window. If exclusive writer protection cannot be demonstrated, use a separate owner-approved canonical standalone QA instead.

Only after a protected, inert QA-specific deployment may temporary, disposable users be provisioned via approved Auth admin and Studio-access paths. Execute three sanitized requests with the real QA project's valid Auth-issued JWT and the synthetic Origin:
1. Active internal staff, active Studio membership, app.access and `ai_studio.ai.use`, valid JSON body: HTTP **503**, no provider path
2. Active internal staff without `ai_studio.ai.use`: HTTP **401**
3. Revoke Studio membership/permission on actor 1 while retaining their JWT: HTTP **401**

Inspect and record server-side body/status, JWT-enabled function metadata, request source hash and zero outbound activity; no credentials, tokens or PII in GitHub evidence. Delete synthetic Auth users and Studio access fixtures, reconcile sessions and no other changes, and restore Genie QA's Edge-zero requirement via separately approved rollback/remove if it is in force. Do not mark Production source as deployed. Production `catalogue-ai-copy` v44 remains behind its separate protected release workflow and Production environment/secret approval.

## 23 November 2026 — protected commissioning readiness candidate

The manual Studio QA commission workflow is SOURCE-ONLY and read-only. It cannot deploy,
delete, create Auth fixtures, access Production or consume STUDIO_QA_DEPLOY_TOKEN.
It checks the exact protected main SHA, a successful protected Studio QA preflight
at that SHA (including the required success steps), the immutable inert two-file
candidate, current isolated QA project identity, provider-secret absence and
zero Edge Functions.

Only mode readiness may pass. Deploy and cleanup modes are hard-stopped before any
mutation and require a future independently CODEOWNER-reviewed release/rollback PR.
The existing genie-qa-bootstrap environment remains protected. Its approval and
GitHub concurrency do not exclude Dashboard/API writers.

EXTERNAL WRITER REMEDIATION: inventory the consumers and scope of all unexpired
legacy/account-level tokens capable of writing to oasis-genie-qa, migrate
conflicting automations and operators to project-scoped credentials excluding
QA with separately reviewed changes, preserve Production clients, and verify
the QA-access and revocation state. Never revoke unknown broad tokens arbitrarily.
Owner confirmation that other writers are paused and temporary use of the
existing QA deployment token were already recorded; neither establishes
provider-enforced exclusivity. If no technically verifiable lease is possible,
seek separate approval for a canonical standalone Studio QA project, including
its cost, instead of repeating failed Dashboard Preview migration cloning.

AFTER UNBLOCKING: approve a separately protected named-function inert deployment
and rollback workflow, fresh read-only preflight, explicit independent QA
environment approval, JWT=true, strict source+function metadata attestation
before/after download, synthetic staff permission tests 503/401/401, and
fixture/session cleanup plus a verified return to shared QA Edge-zero.
No Production deployment, paid provider inference or release certification
may be inferred from this source-only readiness candidate.

## 23 November 2026 — Executive QA-only override and final PR #596

The sole system owner expressly accepts the risks of unrotated legacy Supabase
Management API tokens and absence of an independently enforced external-writer
lock for isolated non-production project oasis-genie-qa (ref
skhpmltfjgqitntkmclb). This waiver applies **only to this QA deployment**,
not to Production, not to other Appverse repositories, and not to automated
merges or credential disclosure. Earlier shared-QA writer-hold statements above
are historical and are superseded solely for the Studio QA deploy/delete job.

Final PR #596 contains a genuinely executable, manually dispatched, protected
GitHub Actions workflow, studio-ai-copy-qa-release.yml. The only user input is
operation: deploy or delete. It is restricted to Core main, the exact QA ref,
and the named catalogue-ai-copy function. The sole write credential is the
existing STUDIO_QA_DEPLOY_TOKEN in the protected QA environment. No other QA
functions, database objects, Production resources or other environments may be
altered by this workflow.

The deploy operation generates the hash-pinned provider-inert two-file bundle,
retaining the original JWT and scoped Studio authorization checks, pins
verify_jwt=true, explicitly sets QA AI_STUDIO_AI_ENABLED=false and deploys
only catalogue-ai-copy. The bundle removes all OpenAI inference calls even
if later secrets drift, giving an additional zero-spend safeguard. GitHub
records a post-write one-function/active/JWT=true verification.

Following staff 503/401/401 UAT, dispatch the same workflow with operation=delete
to remove only the QA function, unset the QA-only AI flag and verify zero Edge
functions; the owner then revokes the temporary token. A failed action is NOT
certified as successful. Protected GitHub workflow review and owner click
remain the only pre-run controls. No new PRs are planned.
