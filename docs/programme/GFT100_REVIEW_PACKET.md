# GFT-100 review packet (Gifting website, Core receiver, Central staff queue)

One packet for the independent reviewer. Review in the order of section 2; each step lists what it is, the evidence, and what
to check. Register: Gifting #2. Cross-repo intake: Central #677. **Release state: NO-GO.**

## 0. Who can review
Needs a person with write access who is not the author. Gifting `main` has **no branch protection or ruleset**, so GitHub
enforces nothing there; the independent review is a process control. The account `dineshmutrejabackup-cmd` is the designated
approver in Core's `CODEOWNERS` but shows no collaborator standing on the Gifting repository (its approval on Gifting #37 was not
counted). Core `main` requires one independent human owner approval; Central `main` reports its PR as `blocked` pending review.

## 1. Release record — previews versus production (corrected)
Earlier status lines said "nothing deployed". That was imprecise. The accurate record:

| | What happened | Evidence |
|---|---|---|
| **Automatic PREVIEW deployments occurred** (not production) | Vercel preview builds for Gifting PRs #39–#45 and Central #681 (project `prj_uwbmF0cG…`, team `team_XMYleETLIA1kDH6q82WzFPf1`; bot comments "Ready"); Netlify deploy previews (`deploy-preview-N--oasisbaklawa.netlify.app`) for Gifting PRs; **Supabase preview branches** created per Core PR with the PR's migrations applied and Edge Functions deployed: `htqvalootmxurzbczxek` (#557, `gifting-enquiries` v1, migration `20261118210000`) and `jlkvioiimtplxhbdqtfq` (#559, queue migration), plus branches for #560/#561 | PR bot comments; Supabase branch list; the #557 branch was inspected and exercised (synthetic UAT) |
| **No production deployment occurred** | No PR in this programme is merged. Production Core's migration ledger ends at `20261114110000`; `gifting_enquiries` does **not** exist in production Core (read-only SQL, 19 Nov); Gifting `main` is still `e298725`; none of these changes is on Core or Central `main`; Lovable was unpublished at `e298725` when last checked; no payment, domain or checkout activation | the heads above, `git log` of each `main`, production ledger query |
| Not observable from the agent session | The state of the Gifting production URL (the Vercel connector returned 404 for the project), and whether any pre-existing production deployment of `main` serves traffic | owner can confirm in Vercel |

Preview infrastructure is temporary: preview branches disappear with their PR; previews of fixture-priced pages are publicly
reachable (Netlify/Vercel) and are not covered by production controls.

## 2. Core, in dependency order
Chain: **#558 → refresh #557 → #559 → #561**, with **#560** (hosted UAT runner) depending on #557 only, then **Central #681**.

| Step | PR (head) | Base | What it is | Evidence | Reviewer checks | After merge |
|---|---|---|---|---|---|---|
| 1 | Core **#558** (`c01d64f`) | `main` | Fixes the shared CI blocker: #553 put a `pull_request` trigger and two protected environments in one workflow, so the preview-secrets guard fails on every Core PR touching edge paths. Cutover becomes `workflow_dispatch`-only; a credential-free PR workflow carries the identical contract job; **the guard is unchanged** | all required checks pass in real CI; new regression test rejects 4 mutations with the real guard; CodeRabbit: no actionable findings | cutover jobs, environments, `if:` gates and `needs:` are byte-identical apart from the trigger; PR contract job identical in both files | unblocks #557, #560, #561 |
| 2 | Core **#557** (`d87320f`, **refresh required**) | `main` | Gifting enquiry receiver: write-only Connect profile, idempotent `gifting_enquiries`, `gifting_enquiry_receive_v1`, `gifting-enquiries` Edge candidate, tests, contract and UAT docs | real CI: clean replay of all migrations + pgTAP pass (`gifting_enquiry_receiver_v1.test.sql ... ok`); synthetic UAT 18/18 on the hosted preview (database level) and 21/21 over local TLS with the website's real sender; mutation-checked | token validation inside the RPC (profile + scope + expiry + revocation); conflict vs replay; no write on rejection; table `service_role`-only | **Refresh:** `git merge origin/main` into the branch (no rewrite). Verified clean on 19 Nov; main gained #543/#550/#556, migration ceiling `20261118110900` is below ours. Expect the two red checks to clear |
| 3 | Core **#559** (`93097de`) | #557 branch | Staff queue RPCs, admin/super_admin only via `is_admin()`; table stays `service_role`-only | real CI green; both Gifting pgTAP files ok (331 files, 5,982 tests) | the authorization helper; returned columns hide hash, consumer, source lead id | retarget to `main` once #557 merges |
| 4 | Core **#561** (`0eebc5f`) | #559 branch | Retail commerce **configuration** infrastructure — **PENDING OWNER APPROVAL, NOT ACTIVATED** (sets no value, approves nothing, produces no quote) | 70 pgTAP assertions + 7 mutation checks locally; real CI: replay + pgTAP, migration contract tests and Codacy pass. The Supabase Preview check failed once with a base-bootstrap collision (`cleanup_archive` schema, statement 10, before this migration runs); the preview branch bot later reported migrations, seeding and edge functions green. Not a defect of this change, but unconfirmed by a green check run | nobody can write settings directly; only an active admin can; approval needs a reference; defaults block everything; `retail_quote_create_v1` can never return a quote | retarget to `main` |
| 4b | Core **#560** (`7f339de`) | #557 branch | Manually triggered synthetic **hosted UAT runner** (isolated preview only) + runbook | 24/24 locally (`--local-test`, not hosted); 11 guard unit tests + workflow contract + real-guard mutations | allow-list and deny list; DB-credential-to-ref binding; preflight; cleanup; redaction scan | owner creates environment `gifting-preview-uat` + secret, then runs it |
| 5 | Central **#681** (`cc6f786`) | `main` | Staff UI `/admin/gifting-enquiries` (typed client, paging, stale-response guard), route/access/authority-matrix/nav registration | real Central CI green incl. typecheck, tests, build, Playwright smoke; 3 CodeRabbit findings fixed and resolved with regression tests | route guard module `clients`; page shows "unavailable"/"administrators only" until Core #557/#559 are applied | none until the Core queue exists in the target database |

Required order of **production-affecting** actions (none authorised, none taken): approvals → merges in the order above →
governed migration release → governed Edge deploy → token provisioning → acceptance. Each is a separate gate.

## 3. Gifting website PRs and outstanding acceptance
`main` is `e298725`. All heads below are green with no unresolved threads.

| Order | PR (head) | Scope | Outstanding acceptance |
|---|---|---|---|
| 1 | **#39** (`fff1853`) | skip link + iOS Back-scroll fix | **physical iOS** Back-restoration check (emulation passed); hosted Preview check |
| 2 | **#40** (`e109260`) | homepage illustrative-price disclosure | hosted Preview check |
| 3 | **#41** (`224dc70`) | fail-closed fixture offers (cards, PDP, cart, builders) | hosted Preview check |
| 4 | **#43** (`dd28399`) | CatalogBrowser price slider/URL `maxPrice` gated. **Stacked on #41** (base = #41 branch); retarget to `main` after #41 | hosted Preview check |
| 5 | **#42** (`f20100a`) | desktop mega-menu overflow (pre-existing on `main`) | hosted Preview; device matrix |
| 6 | **#44** (`79cb1b5`) | one canonical per route | **`SITE_URL`/`VITE_SITE_URL` must be set in the target environment**; final canonical domain decision |
| 7 | **#45** (`26a99e6`) | fail-closed consumer of Core's retail readiness; **pending owner approval, not wired to checkout** | none until retail decisions exist |
| hold | **#37** (`d8a7453`) | verified Central receipt before marking an enquiry synced | **do not merge** until hosted receiver acceptance: operator-issued short-lived preview token in the Gifting Vercel Preview env, then one synthetic enquiry delivered twice with one resulting row |

Combined #39–#44 tree: merges cleanly in the order above, typecheck clean, lint 0 errors, 147/147 tests. #43 depends on #41 for
`retail-offer-policy.ts`; do not merge #43 first.

## 4. Not established (do not infer from green CI)
Hosted HTTP acceptance of the receiver (runner prepared in #560, not run); Gifting Preview → receiver path; physical iOS;
hosted Preview acceptance of #39–#44; retail quote/order/payment/identity/fulfilment (decisions pending — see the configuration
decision sheet); Wix reconciliation; production deployment anything.

## 5. Owner actions (smallest set)
1. One independent write-access reviewer; approve in the order above.
2. Answer the configuration decision sheet (`GIFTING_RETAIL_CONFIGURATION_SHEET.md`).
3. Create the `gifting-preview-uat` environment and secret, then run the hosted UAT (runbook in #560).
4. Issue a short-lived write-only receiver token and store it in the Gifting Vercel *Preview* env; re-authorise the Vercel connector; set `SITE_URL`.
5. Confirm: Netlify project and public repo intent; Wix source site; persistent Core staging target.
6. Physical iOS check of #39.
