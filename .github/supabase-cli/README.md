# Integrity-locked Supabase CLI

`production-migration-release.yml` installs the Supabase CLI from these lockfiles with
`npm ci --ignore-scripts` instead of the `supabase/setup-cli` action.

Why: the action runs a nested `oven-sh/setup-bun` whose post step saves a Bun cache. In run
40114414449 that post step hung after every substantive step had passed, so the preflight job was
cancelled at its 30 minute limit. Post steps cannot carry a step-level timeout. This install path has
no Bun and no post step.

Pinning is unchanged or stronger: exact CLI versions (2.117.0 production-facing, 2.110.0
CI-certified local readiness), with every transitive package and the platform binary package pinned by
`sha512` integrity in `package-lock.json`. The workflow still asserts `supabase --version` equals the
pin.

To change a version: edit `package.json`, run `npm install --package-lock-only --ignore-scripts` in the
version directory, and update the workflow `env` version. Rollback: revert the workflow change.
