---
title: 0.2 — Architecture briefing
sidebar_position: 2
---

# M0.2 — Architecture briefing

## What you will accomplish

A 15-minute briefing that explains:

- Which Azure services are deployed in which region, and why.
- Which decisions in the workshop carry over to a real production
  deployment, and which only exist because we're in a free-tier
  subscription.
- What you should expect to find on the cluster before M1 starts.

This module has no commands to run — it is purely conceptual. If you are
self-pacing, skim the tables and then go to [M1](../gateway-foundations/intro).

## The two-architecture model

Every production deployment of an AI platform in a region with partial
service availability ends up with **two architectures** — one for
development on managed services, and one for production that stays in
country. This workshop teaches both.

### Workshop / dev architecture (what we deploy today)

Used by every hands-on lab in M1–M6. The full Terraform that creates it
is in
[`infra/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/infra).

| Component | Region | Tier |
| --- | --- | --- |
| API Management (AI Gateway) | Indonesia Central | Developer (classic) |
| AKS (agents, MCP, SLM, content safety container) | Indonesia Central | Free, 2× Standard_D4s_v5 |
| Azure AI Search | Indonesia Central | Basic |
| Cosmos DB for NoSQL | Indonesia Central | Standard, provisioned 400 RU/s |
| Application Insights + Log Analytics | Indonesia Central | PerGB2018 |
| Key Vault (RBAC mode) | Indonesia Central | Standard |
| Storage account | Indonesia Central | StandardLRS |
| Container Registry | Indonesia Central | Basic |
| **Azure OpenAI** | **Southeast Asia** | S0 — `gpt-5-mini`, `text-embedding-3-large` |

### Production-target architecture

The architecture you actually want to run in production. Differences from
the workshop architecture are bolded.

| Component | Region | Tier / replacement |
| --- | --- | --- |
| API Management | Indonesia Central | **Premium (classic) — SLA-backed, multi-region capable** |
| AKS | Indonesia Central / on-prem | Standard tier (SLA), GPU node pool added |
| AI Search | Indonesia Central | Basic — *no semantic ranker* (see workaround below) |
| Cosmos DB | Indonesia Central | **Vector search + semantic reranker (Preview)** |
| **Azure OpenAI** | **N/A — replaced** | **Self-hosted SLM (Phi-4-mini / similar) on AKS GPU node pool** |
| **Content Safety** | **Indonesia Central, container on AKS** | **GPU node pool (T4/L4 minimum)** |
| Application Insights | Either, or customer Splunk/Datadog via OTLP | Pay-as-you-go |

### Cross-region traffic in the workshop

Because Azure OpenAI is not in Indonesia Central today, the workshop fans
out to Singapore for LLM and embedding calls. Traffic flows:

```
laptop → APIM (Indonesia Central)
              ↓
        AOAI (Southeast Asia, ~30–40 ms RTT)
              ↑
         response
              ↑
laptop ← APIM (Indonesia Central)
```

This is acceptable for dev. For production, the same APIM stays in IDC
but the backend pool points at a self-hosted SLM running in your AKS in
IDC, and the cross-region hop disappears.

## Decision matrix — API Management tier

You will hit this table again at the end of the day. Memorize it.

| Tier | Available in IDC | SLA | Self-hosted gateway support | When to use |
| --- | --- | --- | --- | --- |
| Developer (classic) | ✅ | None | ✅ | Workshop, dev, demos |
| Premium (classic) | ✅ | 99.95% (multi-region 99.99%) | ✅ | Production in regions where v2 isn't yet available |
| Basic v2 / Standard v2 | ❌ | 99.95% | ❌ | Production in regions where v2 is available |
| Premium v2 | ❌ | 99.99% | ✅ (workspace gateway) | Production in v2 regions; multi-tenant |
| Self-hosted gateway on customer AKS | ✅ anywhere | Customer-managed | n/a | On-prem prod; air-gapped scenarios |

Source: [APIM region availability](https://learn.microsoft.com/azure/api-management/api-management-region-availability).

## What's NOT deployed by default

- **Foundry Hosted Agents** — Public Preview, available in Southeast
  Asia but not IDC. Optional demo in [M4](../agent-framework/intro).
- **GPU node pool** — out of scope for the workshop CPU cluster.
  Production path is documented in
  [M2](../finops-observability-security/intro).
- **vLLM-served SLM** — same reason. We use llama.cpp + a CPU build of
  Phi-4-mini in M1 to keep the demo fast.
- **APIM v2 tiers** — not available in IDC. Concept-only discussion in
  the wrap-up.

## Verify the landing zone is reachable

The facilitator runs the
[`smoke-test`](../90-facilitator-guide/provision.md) script the morning
of the workshop. If you completed M0.1 Step 5 and got a response back
from the gateway, the landing zone is up — proceed to M1.

If your curl returned a non-2xx, flag your facilitator before continuing.

## Next

[M1 — Gateway Foundations](../gateway-foundations/intro)
