# WA-E2E — Mission Control Audit

**Project:** WA-E2E  
**Authority:** Appverse Mission Control  
**Scope:** Complete official Oasis Baklawa WhatsApp system only  
**Core main audited:** `9d6f18bcba7a91958cdb43e1b2a1d3772626b7ce`  
**Stabilization branch:** `cursor/wa-stabilize-baseline-e6ae` (audit refresh + harness port; no deployment)  
**Production:** `tcxvcatsqqertcnycuop` — **FORBIDDEN** for certification writes  
**Audit date:** 2026-09-01 (current-main stabilization baseline)  

Permanent invariants under test:

- every inbound message is not necessarily an order;
- sender is not necessarily the customer;
- employees may place orders for actual customers;
- never invent customer, SKU, price or quantity;
- never default quantity to 1;
- unresolved material facts fail closed;
- later corrections supersede older facts;
- duplicate forwarding must not duplicate work;
- every meaningful inbound ends in an accountable state;
- forwarding is not resolution;
- provider uncertainty is reconciled, not falsely terminalized;
- non-order communication must not disappear.

---

## Preserved certification evidence (historical/provisional metadata; do not reopen #148 / #154)

| Stage | Verdict | Evidence anchor | Notes |
|---|---|---|---|
| **Stage 1B** | **PASS** | run `b7635232-a9a3-49d8-806a-e749a2b8d8f9` | 24/24 mandatory fixtures; Gates A–E PASS; zero-tolerance counters all 0. Runtime/infrastructure fixes canonicalized via merged **#147**. Closed evidence PR **#148** — do not reopen or merge wholesale. |
| **Stage 2 historical** | **PENDING** | corpus SHA `ae6b6bfecfdce8b6873a650815d14e3d2f929ef1e47ddf880397357d36c2f0c9` | Preserved historical/provisional metadata from the prior `wa-stage2-historical/v2` PASS: 8,911/8,911 executed/scored; aggregate governed routing benchmark 100%; `unaccounted_potential_orders=0`. The prior v2 PASS is **invalidated** after routing/reconciliation integrity repairs. Stage 2 certification remains **pending** until a fresh full protected-corpus run under schema `wa-stage2-historical/v3` completes. Closed evidence PR **#154** — do not reopen or merge wholesale. `stitching`, `dedup`, `mixed_intent` were **NOT_EVALUATED** by Stage 2 and must not be misrepresented as Stage-2 PASS dimensions. |

---

## 1. VERIFIED DONE (Core `main` + pgTAP / harness evidence)

### Ingress and immutable capture

| Capability | Evidence |
|---|---|
| WA-1 zero-loss potential-order authority | `20260813120000_wa1_*`, reconciliation view, `unaccounted_potential_orders = 0` pgTAP |
| Durable inbound capture | `ingest_whatsapp_inbound_message`, `whatsapp_inbound_messages`, idempotent on `provider_message_id` |
| Media ingress ≠ terminal failure | PR #128 merged; `20260827230000_wa_stage1_media_ingress_certification.sql` (22/22) |
| Noncommercial media completion | PR #134; `20260829070000_wa_noncommercial_media_completion.sql` |
| Click2API/Meta webhook security | Token + HMAC modules; recertification docs |
| Legacy auto-order writes gated off | `ENABLE_WA_WEBHOOK_AUTO_ORDER_WRITES=false` default; governance logs when skipped |

### Stitching, dedup, and mixed-intent (pgTAP — not Stage-2 historical dimensions)

| Dimension | Executable evidence on current `main` | What it proves |
|---|---|---|
| **stitching** | `20260816120000_wa_atomic_packet_authority.sql` (23 tests); `20260813180000_wa4_multimessage_multimodal.sql` (explicit conversation stitching, cross-customer fail-closed); `20260822100000_whatsapp_packet_ai_dispatch_outbox.sql` (correction restitch idempotency) | Atomic per-contact stitching; explicit packet continuation; window exceeded fails closed; cross-contact rejected |
| **dedup** | WA-4 pgTAP provider replay idempotency (`wa4-first` replay); WA-1 `source_fingerprint` unique index; atomic packet `provider_message_id` unique constraint (`23505` on duplicate raw row); WA-3 hostile duplicate-forward idempotency | Provider retries and duplicate forwards do not duplicate evidence or commercial work |
| **mixed_intent** | `20260831101900_wa_stage1b_unclear_clarification_autonomy.sql` (`s1b_mixed`: RESOLVED + UNRESOLVED lines must not become `AUTO_ELIGIBLE`); CORE-C pgTAP non-order routing taxonomy | Mixed resolved/unresolved commercial lines fail closed to autonomy; non-order intents governed separately |

### Interpretation and autonomy (order path)

| Capability | Evidence |
|---|---|
| Governed packet AI interpretation | `#82`, `#84`, hardening closures |
| Direct Gemini multimodal worker + operator interpret helper | **#147 merged**; shared `_shared/geminiProvider.ts`; `whatsapp-content-interpret` and `whatsapp-packet-ai-worker` unified on direct Gemini transport |
| CORE-A validation + governed facts | `#111`, `20260823100000_whatsapp_autonomy_core_a.sql` |
| CORE-B autonomous draft + SO continuation | `#112`, `20260823110000_whatsapp_autonomy_core_b.sql` |
| CORE-C clarification resume + non-order governance | `#114`, `#144`, CORE-C pgTAP suite |
| Gate 11 commercial-invention hardening | `#116`, dangerous false-positive = 0 in pgTAP |
| Cross-packet clarification lineage | `#102` |
| Case ↔ potential-order bridge | `#99` |
| Knowledge bridge snapshots | `#121`, activation RPCs |
| Stage-1B unclear clarification semantics | `20260831101900_wa_stage1b_unclear_clarification_autonomy.sql` via #147 migration governance |

### Non-order path

| Capability | Evidence |
|---|---|
| B2B case orchestration | `#84`, decision lifecycle migrations |
| Non-order routing (ENQUIRY/COMPLAINT/PAYMENT/DELIVERY) | CORE-C pgTAP; suppressed receipt closure |
| `whatsapp_apply_non_order_case_governance_v1` | team routing + SLA |
| Payment proof capture (non-order) | payment authority migrations + case review RPCs |

### Operator governance (Core RPC layer)

| Capability | Evidence |
|---|---|
| WA-2 identity/RBAC | permission matrix pgTAP |
| WA-3 clarification + promotion | `approve_sales_order_draft_for_so_atomic`, hostile tests |
| WA-5 operator reply outbox | idempotency pgTAP |
| WA-6 commercial disclosure | recipient-bound authorization pgTAP |
| WA-7 release aggregate invariants | `20260813210000_wa7_whatsapp_release_certification.sql` |

### Central operator UI (Oasis-Baklawa-Central)

| Capability | Evidence |
|---|---|
| Operator Inbox shell | `/admin/operator-inbox`, virtualized packets, realtime |
| Decision Desk + 10-section case lifecycle | governed RPC wiring |
| Sales Order Draft section | Core RPC promotion path |
| WA-1/3/4 accountability strips | reconciliation + clarification + evidence views |
| Resolution panels (sender/client/product/qty) | read-only suggestion layers |
| Permission gating | `get_my_whatsapp_permissions`, `WhatsAppPermissionRoute` |

### Harnesses (current `main` after stabilization port)

| Harness | Status |
|---|---|
| CERT-A sanitized (12 cases) | CI on PR; `scripts/whatsapp-autonomy-eval/` |
| Stage-1B fixture manifest + edge runner | `supabase/functions/_shared/stage1bCert/` + `whatsapp-stage1b-cert-runner`; local orchestrator `scripts/whatsapp-stage1b-cert/run.ts` |
| Stage-2 historical harness (reproducibility) | `scripts/whatsapp-stage2-historical/` + preserved **provisional** metadata `artifacts/wa-stage2-historical/report.json` (no corpus in Git; v3 rerun required) |
| Protected corpus runner hardening (#154 port) | `hash.ts`, `runProtectedCases`, `core_runner.test.ts` collision-resistant namespace |

---

## 2. Edge Function disposition matrix (current `main`; no deployment implied)

| Function | Disposition | Source | Registry / config | Notes |
|---|---|---|---|---|
| `whatsapp-webhook` | **CERTIFY** (quarantined) | `supabase/functions/whatsapp-webhook/` | Live v121; `failed-certification-continued-quarantine`; **not** in `config.toml` | Official production ingress; capture-only path certified in repo; production activation blocked |
| `whatsapp-studio-inbox-bridge` | **CURRENT** (controlled manual) | repository-present | Live v29; `certified-controlled-manual-only` | Parallel ingress; cron disabled by default |
| `whatsapp-packet-ai-worker` | **CERTIFY** (preview) | repository-present | Outside 26-function live inventory; `config.toml` preview-only | Trusted packet AI processor; service-role body auth |
| `whatsapp-content-interpret` | **CERTIFY** (preview) | repository-present | Outside live inventory; `config.toml` preview-only | Operator read-only interpret helper; JWT + RLS |
| `whatsapp-reconciliation-worker` | **CERTIFY** (preview) | `supabase/functions/whatsapp-reconciliation-worker/` | **Not** in `config.toml` or live registry | Source exists; deploy/schedule not declared; calls `whatsapp_run_system_reconciliation` |
| `whatsapp-stage1b-cert-runner` | **CERTIFY** (preview-only) | repository-present | `config.toml`; explicitly excluded from production registry | NON-PRODUCTION; `WA_STAGE1B_CERT_SECRET` custom auth |
| `whatsapp-message-stitcher` | **RETIRE** | missing-canonical-capture | Live v27 | Superseded by Core RPC `stitch_whatsapp_messages_atomic` |
| `whatsapp-identify-sender` | **RETIRE** | missing-canonical-capture | Live v24 | Legacy pipeline; DB RPCs supersede |
| `whatsapp-classify-intent` | **RETIRE** | missing-canonical-capture | Live v21 | Legacy pipeline |
| `whatsapp-route-packet` | **RETIRE** | missing-canonical-capture | Live v21 | Legacy pipeline |
| `whatsapp-studio-inbox-webhook` | **RETIRE / reconcile** | missing-repository-source | Live v19 | Parallel legacy ingress without canonical repo source |
| `send-whatsapp` | **CURRENT** (live) | missing-canonical-capture | Live v108 | Outbound provider send; audit-and-capture pending |
| `whatsapp-operator-reply` | **CURRENT** (live) | missing-canonical-capture | Live v25 | Operator reply path; governed by WA-5 RPC layer |
| `generate-product-attributes` | **RETIRE** | repository-tombstone (410) | Live v96; runtime removal pending | Must not be re-enabled |

---

## 3. PARTIALLY DONE

| Item | Current state | Remaining |
|---|---|---|
| **Production edge activation** | Source in Core for webhook, bridge, packet worker, content-interpret, reconciliation worker | Packet AI worker, content-interpret, reconciliation worker **not** in 26-function live inventory; webhook **quarantined** in registry |
| **Legacy edge pipeline** | DB RPCs supersede stitcher/classify/route | Live functions without canonical repo source still deployed (see RETIRE matrix) |
| **Central clarification UX** | PR #420 wires product chips → `whatsapp_capture_learning_candidate` | Server-persisted operator notes/views still local-only (Core RPC missing) |
| **Central typegen** | Case RPCs called via unchecked invoker | `database.types.ts` lags Core case RPC surface |
| **Operator draft extraction panel** | Local workflow only | Does not persist governed corrections to Core |
| **Reconciliation worker** | Source exists | Not in `config.toml`/registry; deploy/schedule not certified |
| **Studio inbox bridge** | Certified controlled-manual-only | Cron disabled; parallel ingress path vs native WA-1 webhook |
| **95% / Stage-2 historical benchmark** | Prior v2 PASS metadata preserved; harness now on `main` | Fresh v3 protected-corpus run required before release use; rerun only on semantic regression |
| **Central gap matrix** | Documents C1–C4 | Partially stale: WA-1/CORE-A/B/C address several items |
| **Legacy webhook Lovable parser** | Auto-order path gated off | `whatsapp-webhook` still references `LOVABLE_API_KEY` for optional legacy extraction — migrate or retire separately |

---

## 4. MISSING

| Item | Impact |
|---|---|
| **Live-number WA-7 certification procedure** | Production go-live blocked per runbook NO-GO |
| **Gate 12 festival load/chaos** | No staging load evidence |
| **Gate 14 pre-production claim** | Synthetic pass ≠ staging/provider certified |
| **Cross-repo staging E2E** | Order + non-order paths not proven end-to-end in deployed preview |
| **Real non-production provider proof** | Click2API post-deploy sign-off withheld |
| **Canonical source for live-only legacy edges** | stitcher, identify-sender, classify-intent, route-packet, studio-inbox-webhook |
| **GPT Finance handover contract test** | WhatsApp → Finance boundary not certified in this audit |
| **End-of-shift reconciliation UI workflow** | Core RPCs exist; operator shift-close UX incomplete |
| **Server-persisted operator corrections** | Business-significant edits still local in places |

---

## 5. BROKEN / REGRESSED

| Item | Evidence | Severity |
|---|---|---|
| **Webhook production quarantine** | Registry: `failed-certification-continued-quarantine` | Production ingress not certified for activation |
| **Click2API runtime sign-off withheld** | `WHATSAPP_CLICK2API_RUNTIME_EVIDENCE_2026-08-01.md` | Provider ingress not closed |
| **Legacy webhook order mutation path** | Code still present when `ENABLE_WA_WEBHOOK_AUTO_ORDER_WRITES=true` | Must remain disabled; path is CONTRADICTORY if re-enabled |
| **Case may not exist for every packet** | Central Decision Desk amber when no `whatsapp_communication_cases` row | Operator workflow gap for unstitched/uninterpreted packets |

No open **software defect** is confirmed on Core `main` pgTAP at audit head `9d6f18b` beyond certification/runtime activation gaps.

---

## 6. BLOCKED BY EXTERNAL AUTHORITY

| Blocker | Owner action required |
|---|---|
| **Production deployment** | Separate explicit authorization; controlled release runbook |
| **Protected historical WhatsApp export** | Owner must provide sanitized corpus outside Git for Stage-2 reruns |
| **Live Click2API/Meta provider proof** | Owner/provider sign-off |
| **Mission Control GO/NO-GO** | Cannot declare WA-E2E complete until Gates 10–14 + live cert pass |
| **Preview Edge Runtime secrets for Stage-1B reruns** | `GEMINI_API_KEY`, `WA_STAGE1B_CERT_SECRET`, derived `WHATSAPP_MEDIA_ALLOWED_HOSTS` on preview `jyezfiehhfgnvhzzffxr` |
| **Local pgTAP / clean replay in Cloud Agent VM** | Docker unavailable in current agent environment; full Migration CI pgTAP runs on GitHub Actions |

---

## Order path — current canonical chain (Core `main`)

```
official ingress (whatsapp-webhook / bridge)
  → ingest_whatsapp_inbound_message (immutable)
  → studioInboxFanOut → capture_whatsapp_commercial_fragment (WA-4)
  → stitch_whatsapp_messages_atomic
  → enqueue_whatsapp_packet_ai_dispatch
  → whatsapp-packet-ai-worker (Gemini multimodal)
  → whatsapp_persist_packet_ai_interpretation_governed
  → whatsapp_evaluate_and_materialize_order_autonomy (CORE-A)
  → [CLARIFICATION] CORE-C enqueue/resume
  → whatsapp_execute_autonomous_order_draft_v1 (CORE-B)
  → approve/promote_sales_order_draft_for_so_atomic (WA-3)
  → handover toward GPT Finance (downstream — not certified here)
```

## Non-order path — current canonical chain (Core `main`)

```
same ingress → interpretation (non-order intent)
  → whatsapp_materialize_packet_ai_case
  → whatsapp_apply_non_order_case_governance_v1
  → operator Decision Desk (Central)
  → governed reply / escalation / closure (WA-5/6 + case RPCs)
```

---

## Autonomous work queue (Cursor ownership)

Priority order while external blockers remain:

1. **Production/runtime activation** — Procedure 8 only; webhook de-quarantine requires live-number WA-7 pass  
2. **Retire legacy live-only edges** — stitcher, classify, route, identify-sender per matrix above  
3. **Declare reconciliation worker** in registry/config when preview certification is scheduled  
4. **Bridge Central draft extraction panel** to governed draft RPCs  
5. **Cross-repo staging E2E** — order + non-order to accountable outcomes  

Do **not** reopen or merge closed evidence PRs **#148** or **#154** as shortcuts.

---

## Completion criterion

Mission Control may declare **CURSOR — WA-E2E COMPLETE** only when:

- Stage 1B live media certification remains valid or is re-passed after material runtime change
- Live-number WA-7 procedure passes on isolated preview
- Historical benchmark remains valid or is re-scored on protected corpus when semantics change
- Cross-repo E2E proves order and non-order paths to accountable outcomes
- Production activation explicitly authorized and certified
- `unaccounted_potential_orders = 0` under load/replay/reconciliation

**Current verdict:** WA-E2E **NOT COMPLETE** — preserved Stage-1B PASS evidence stands; Stage-2 remains **pending** fresh v3 certification; **production/runtime/live provider gates remain open**. Software baseline on `9d6f18b` is stable; activation and live certification are the remaining blockers.
