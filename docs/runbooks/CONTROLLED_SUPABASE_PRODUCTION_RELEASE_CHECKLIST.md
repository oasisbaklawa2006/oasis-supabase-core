# Production Migration Release Activation Checklist

Complete once after merging the controlled release pipeline.

- [ ] Create GitHub environment `supabase-production-readonly`.
- [ ] Set environment variable `SUPABASE_PROJECT_REF` to `tcxvcatsqqertcnycuop`.
- [ ] Add read-only/preflight secrets `SUPABASE_DB_URL`, `SUPABASE_ACCESS_TOKEN`, and `SUPABASE_DB_PASSWORD`.
- [ ] Create GitHub environment `supabase-production`.
- [ ] Restrict deployment branches to `main`.
- [ ] Require a production reviewer and prevent self-review where supported.
- [ ] Add production deployment secrets only to this environment.
- [ ] Require `Migration naming, safety and contract tests` on pull requests.
- [ ] Require `Clean database replay and pgTAP contracts` on pull requests.
- [ ] Require CODEOWNER review for migrations and production release workflows.
- [ ] Merge the controlled release PR after CI passes.
- [ ] Approve the first production release only after examining its dry-run artifact.
- [ ] Confirm `20260730170000_customer_contract_privilege_hardening` appears in the production ledger.
- [ ] Confirm the post-deployment ledger report shows `Pending append-only versions: none`.
- [ ] Confirm the next scheduled drift watch is green.

Do not enable or approve production writes until the environment project reference and secrets have been independently checked against project `tcxvcatsqqertcnycuop`.
