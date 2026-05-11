# Contributing

Thanks for considering a contribution to the Hybrid AI Platform Workshop.

## What this repo is

A **workshop landing zone** — Terraform + APIM policies + Docusaurus
content — intended to be forked and adapted to each facilitator's target
region, customer, and model choices. It is not a product; it is a teaching
artifact.

## What kinds of contributions are welcome

- **Bug fixes** to the Terraform (wrong arguments, deprecated provider
  syntax, missing role assignments).
- **Doc fixes** — typos, broken links, regional facts that have changed
  since the last verification date stamped at the top of each doc.
- **New region recipes** — if you've run the workshop against a region
  with full service coverage (e.g. `westeurope`), a short PR that adds
  a `infra/env/<region>.tfvars` plus a one-page docs note is welcome.
- **Stronger defaults** — moving us toward a more production-aligned
  posture without breaking the workshop UX (e.g. private endpoints
  added as opt-in via a variable).

## What is out of scope

- Customer-specific branding, logos, or wording. Keep the materials
  generic — they are reused for many different workshops.
- New modules (M7, M8, …). The 6-module arc is a deliberately tight
  1-day shape.
- Dependencies on private services or paid SaaS without an open
  alternative.

## Process

1. Fork and create a feature branch (`git checkout -b feat/<short-name>`).
2. Make your change.
3. Run the local checks:
   ```bash
   # Terraform
   cd infra && terraform fmt -recursive && terraform validate

   # Docs
   cd ../docs-site && npm run build
   ```
4. Open a PR with a short description: what changed, why, how you
   verified it.

## Verification dates

Many docs have a "verified May 2026" annotation. If you update a fact,
update the date or remove the annotation. **Do not** leave stale
"verified" claims on content you haven't re-checked.

## Code of Conduct

By participating you agree to abide by the
[Code of Conduct](./CODE_OF_CONDUCT.md).
