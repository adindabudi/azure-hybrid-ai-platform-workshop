# Security policy

## Reporting a vulnerability

If you believe you have found a security vulnerability in this workshop —
in the Terraform code, the APIM policy fragments, the docs, or the
GitHub Actions workflow — **please do not open a public GitHub issue**.

Instead, email the maintainer privately (see `git log` for the
maintainer address, or open a private security advisory on GitHub at
**Security → Report a vulnerability**).

Please include:

- A description of the issue and its potential impact.
- Steps to reproduce.
- Any affected file paths and (if applicable) Terraform / APIM versions.

You should receive an acknowledgement within a few working days.

## Scope

This repository is **workshop / sample code**. It is **not** a production
system, and it intentionally trades off some hardening for clarity:

- APIM is deployed in the **Developer** tier (no SLA).
- AKS is created with `local_account_disabled = false` so the
  workshop's `az aks get-credentials` flow works.
- AI Search is deployed with `local_authentication_enabled = true`.
- Key Vault is created with `purge_protection_enabled = false`.
- Storage is created with `shared_access_key_enabled = false` (good)
  but is otherwise public-network-accessible.

The production hardening checklist in
[`docs-site/docs/99-wrap-up/index.md`](./docs-site/docs/99-wrap-up/index.md)
documents what to flip before deploying any of this against real workloads.

## What is and isn't in scope for a security report

**In scope**

- Hard-coded secrets, tokens, or credentials accidentally committed.
- Terraform that would create resources with publicly exposed sensitive
  data (e.g. world-readable blob containers).
- APIM policies that fail-open in unexpected ways.
- Insecure defaults that a workshop attendee could carry into production.

**Out of scope**

- Anything in `apps/content-safety-cpu/*.yaml` where the user is expected
  to substitute their own secret values (the manifests ship with
  `REPLACE_ME` placeholders).
- The workshop's intentional dev-only trade-offs listed above when used
  in the documented workshop context.
- Issues in upstream dependencies (Azure provider, Docusaurus, etc.) —
  report those to the upstream project.
