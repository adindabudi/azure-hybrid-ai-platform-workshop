# Hybrid AI Platform Workshop

> A 1-day, hands-on workshop landing zone for building a production-grade **AI
> gateway + agent platform** that spans Azure managed services and on-prem
> (or in-country) Azure Kubernetes Service.
>
> Designed to be honest about what runs in regions with **partial Azure
> service availability** — and what you have to fan out to a neighbouring
> region for. Substitute "Indonesia Central" with any region in the same
> situation and the architecture decisions carry over.

The accompanying **module-by-module guide** lives at
[`docs-site/`](./docs-site/) (Docusaurus). It is published to GitHub Pages
on every push to `main` — see [Deploying the docs](#deploying-the-docs) below.

## Repo layout

```
hybrid-ai-platform-workshop/
├── README.md
├── LICENSE                  # MIT
├── SECURITY.md              # how to report vulnerabilities
├── CONTRIBUTING.md
├── CODE_OF_CONDUCT.md
├── .github/workflows/       # CI: docs deploy + terraform validate
├── infra/                   # Terraform landing zone
│   ├── main.tf              # Root module wiring the modules together
│   ├── providers.tf         # azurerm + azapi + alias for the AOAI region
│   ├── variables.tf         # All knobs (attendee_count, prefix, regions…)
│   ├── outputs.tf           # Endpoints, IDs, connection strings (sensitive)
│   ├── locals.tf            # Naming + tagging helpers
│   ├── env/
│   │   └── workshop.tfvars  # Sample tfvars — override with your own
│   └── modules/
│       ├── networking/      # VNet, subnets, NSGs
│       ├── observability/   # Log Analytics + Application Insights
│       ├── data/            # AI Search, Cosmos, KV, Storage, ACR
│       ├── aoai-singapore/  # Provider alias for cross-region AOAI
│       ├── apim-developer/  # APIM Developer (classic) + system MI
│       └── aks/             # AKS + workload identity + OIDC issuer
├── apps/                    # Sample manifests (Content Safety container, …)
├── docs-site/               # Docusaurus site (GitHub Pages target)
├── policies/                # APIM policy fragments (XML)
└── scripts/                 # Bootstrap, smoke-test, verify helpers
```

## What the workshop demonstrates

A six-module arc that takes you from raw Azure subscription to a working AI
gateway plus a multi-runtime agent. The full breakdown lives in the
[docs site](./docs-site/docs/):

- **M0** — Setup and architecture briefing (two-architecture model:
  managed cloud for dev, in-country / on-prem for prod).
- **M1** — APIM as AI Gateway (token limit, semantic cache, content
  safety, priority-based load balancing).
- **M2** — FinOps + observability + security (emit-token-metric, KQL
  dashboards, JWT validation, Content Safety policy).
- **M3** — MCP servers behind APIM (OAuth 2.0 / PKCE, rate-limit-by-key).
- **M4** — Microsoft Agent Framework: the same agent across four
  runtimes (AOAI / self-hosted SLM / LiteLLM / Foundry Local) — switched
  by one environment variable.
- **M5** — Evaluation (Foundry evaluators, DeepEval, Ragas) and local
  red teaming (PyRIT).
- **M6** — OpenTelemetry end-to-end into Application Insights or any
  OTLP-compatible backend.

## Quick start (facilitator)

> Read [`infra/env/workshop.tfvars`](./infra/env/workshop.tfvars) and the
> variables in [`infra/variables.tf`](./infra/variables.tf) first. At
> minimum you must override `apim_publisher_email`, and you may want to
> change `location` / `location_aoai` to match the Azure regions you have
> available.

```bash
# 1. Create the workshop resource group out-of-band so that `terraform
#    destroy` does not cascade into it. Replace name + region as needed.
az group create -n rg-aigw-workshop -l indonesiacentral

# 2. Plan + apply the landing zone
cd infra
terraform init
terraform plan \
  -var-file=env/workshop.tfvars \
  -var="apim_publisher_email=you@yourdomain.com" \
  -out=tf.plan
terraform apply tf.plan
```

The first apply takes ~25–30 minutes — APIM Developer is the long pole.
**Run the apply the day before the workshop.**

> AKS Cilium activation is a two-step migration on the first deploy of
> any existing classic `azure`-plugin cluster. See `enable_cilium` in
> [`infra/variables.tf`](./infra/variables.tf) — set it to `false` on
> the first apply, then `true` on the second apply. A new greenfield
> cluster can start at `true`.

## Per-attendee bootstrap (after `terraform apply`)

```bash
cd ../scripts
./bootstrap-attendees.sh            # creates N namespaces + APIM subs
./print-attendee-handout.sh 03      # prints connection details for #03
```

## Why the workshop has a "cross-region" story

Several services in this workshop's primary example region (Indonesia
Central) are **not yet available** there in May 2026:

- Azure OpenAI
- Foundry Hosted Agents (Preview)
- Azure Container Apps
- Azure AI Search semantic ranker

The workshop deploys those to the closest available region (Southeast
Asia / Singapore) for dev use, and **explicitly documents the in-country
production replacement** for each one (e.g. self-hosted SLM on AKS,
Content Safety container, Cosmos DB vector + semantic reranker). The
same playbook applies to any region with partial Azure coverage.

If you are running the workshop in a region with **full coverage** (e.g.
`westeurope`, `eastus`), set `location = location_aoai = "<your region>"`
in `workshop.tfvars` and the cross-region module simply collapses into
a same-region deploy.

## Cost ceiling (10-attendee, 1-day workshop)

Numbers below were verified on **May 17, 2026** against the
[Azure Retail Prices API](https://learn.microsoft.com/rest/api/cost-management/retail-prices/azure-retail-prices)
for the regions this repo actually deploys into
(`indonesiacentral` for the primary RG, `southeastasia` for AOAI +
Content Safety + the opt-in Managed Redis). Re-verify before each run
— Azure prices move and per-region surcharges change:

```bash
# example: APIM Developer @ indonesiacentral
curl -sG https://prices.azure.com/api/retail/prices \
  --data-urlencode "\$filter=serviceName eq 'API Management' \
    and skuName eq 'Developer' and armRegionName eq 'indonesiacentral'"
```

### Baseline (deployed by `terraform apply -var-file=env/workshop.tfvars`)

| Component | Region | SKU | Hourly | Workshop-day (24 h) | ~Monthly |
|---|---|---|---|---|---|
| APIM | indonesiacentral | Developer (classic) | $0.0658 | $1.58 | ~$47 |
| AKS node pool (2× `Standard_D4s_v5` Linux) | indonesiacentral | Base | $0.432 | $10.37 | ~$311 |
| AI Search | indonesiacentral | Basic | $0.101 | $2.42 | ~$73 |
| Cosmos DB (NoSQL + vector) | indonesiacentral | 400 RU/s shared @ DB | $0.032 | $0.77 | ~$23 |
| Container Registry | indonesiacentral | Basic | $0.007 | $0.17 | ~$5 |
| Storage / Key Vault / LAW / App Insights | indonesiacentral | Std_LRS + pay-per-GB ingest | — | ~$0.30 | ~$10 |
| Content Safety (text & image) | southeastasia | **F0 (free)** | $0 | $0 | $0 |
| AOAI `gpt-5-mini` Global PAYG | southeastasia | $0.45 in / $3.60 out per 1M tok | pay-per-use | ~$2-5 | varies |
| AOAI `text-embedding-3-large` Global | southeastasia | $0.13 per 1M tok | pay-per-use | <$0.10 | varies |
| **Baseline total (always-on infra + typical tokens)** | — | — | — | **~$17-20/day** | **~$469/mo + tokens** |

### Opt-in add-ons (off by default; toggle in [`infra/env/workshop.tfvars`](infra/env/workshop.tfvars))

| Add-on | Toggle | Region | SKU | Day | ~Month |
|---|---|---|---|---|---|
| Azure Managed Redis ([semantic cache backing](policies/llm-semantic-cache-lookup.xml)) | `enable_semantic_cache = true` | southeastasia | `Balanced_B0` (smallest valid) | $0.48 | ~$14 |
|  |  | southeastasia | `Balanced_B5` (recommended for live cache-hit demos) | $4.63 | ~$139 |
| Foundry project ([RedTeam](apps/eval-suite/redteam.py) + `FoundryEvals`) | `enable_foundry_project = true` | eastus2 / francecentral / swedencentral / switzerlandwest / northcentralus | AIServices S0 (platform free) | $0 + tokens at AOAI rates above | $0 + tokens |
| Content Safety **S0** (production-realistic limits, drops the 1K req/day F0 cap) | `content_safety_sku = "S0"` | southeastasia | S0 | ~$0.50 (for ~1,300 text records) | pay-per-use |

Tear down with `terraform destroy` after the workshop — APIM Developer
takes ~10 min to delete; Managed Redis ~5 min on top if it was enabled.

## Deploying the docs

The docs site is a stock Docusaurus 3 install at [`docs-site/`](./docs-site/).
A GitHub Actions workflow at
[`.github/workflows/deploy-docs.yml`](./.github/workflows/deploy-docs.yml)
builds and publishes to GitHub Pages on every push to `main`.

To preview locally:

```bash
cd docs-site
npm install
npm run start          # http://localhost:3000/azure-hybrid-ai-platform-workshop/
```

Before the first deploy, edit
[`docs-site/docusaurus.config.ts`](./docs-site/docusaurus.config.ts) and
update `url`, `baseUrl`, `organizationName`, and `projectName` to match
the GitHub org / repo you forked into.

## Security

See [SECURITY.md](./SECURITY.md). Please **do not** open public issues for
suspected vulnerabilities.

## License

[MIT](./LICENSE). The workshop materials are intended to be forked and
adapted — substitute your own region, customer name, and model choices
freely.

## Acknowledgements

The APIM policy patterns lean on these reference repos:

- [`Azure-Samples/openai-apim-lb`](https://github.com/Azure-Samples/openai-apim-lb)
- [`Azure-Samples/AI-Gateway`](https://github.com/Azure-Samples/AI-Gateway)
- [`Azure-Samples/remote-mcp-apim-functions-python`](https://github.com/Azure-Samples/remote-mcp-apim-functions-python)
