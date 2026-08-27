# WhatsApp Release Certification — Isolated Staging Session

This branch exists only to provision and certify an isolated Supabase preview environment for the WhatsApp release-certification programme.

## Authority

- Canonical Core base: `f8a850c39e5662d9ada5d16c30682d4ae2e2f516`
- Certification branch: `cert/wa-release-cert`
- Production project: `tcxvcatsqqertcnycuop`
- Production must remain untouched.

## Rules

1. This branch is a certification harness/provisioning branch, not a feature branch.
2. Do not merge this PR into `main` merely to complete certification.
3. Do not point certification scripts at the production database.
4. Any remote database used by CERT-A must pass the merged `validateCertDatabaseTarget()` protections.
5. Historical WhatsApp exports remain outside Git. Only sanitized derived fixtures may be used.
6. Synthetic CERT-A remains a safety regression harness; representative historical traffic is the source for real straight-through/accuracy measurement.
7. Required release evidence remains: protected historical benchmark, cross-repo staging E2E, reliability/load/chaos/reconciliation, real provider proof, final release ledger.
8. Production deployment requires separate explicit authorization.

## Exit

After certification evidence is complete, close this PR and retire the preview branch unless it is deliberately retained for future certification.
