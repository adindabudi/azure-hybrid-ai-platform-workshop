---
slug: /
title: Welcome
sidebar_position: 1
---

# Hybrid AI Platform Workshop

Build a production-grade AI gateway and agent platform that spans Azure
managed services and on-prem (or in-country) Azure Kubernetes Service.

## Who this workshop is for

You have shipped at least one application with the Azure OpenAI SDK, or
built an agent with LangGraph / LangChain. You are comfortable on the
command line with `kubectl`, `terraform`, and `az`. You want to move beyond
"call the SDK from the app" and build the gateway, observability,
guardrails, and agent runtime that production demands.

## What you will build

By the end of the day, you will have:

1. An **AI Gateway** (Azure API Management) fronting two model backends —
   one managed (Azure OpenAI) and one self-hosted (Phi-4-mini on AKS) —
   with token limits, semantic cache, content-safety scanning, priority-
   based load balancing, and per-tenant rate limits.
2. Live **token-cost telemetry** flowing into Application Insights, broken
   down by subscription, API, operation, model, and client IP.
3. A **multi-runtime agent** built with Microsoft Agent Framework that hits
   four different backends — managed cloud, self-hosted SLM, LiteLLM, and
   the architect's laptop — switched by a single environment variable.
4. A reproducible **OpenTelemetry** pipeline showing one trace per user
   request, end-to-end: laptop → gateway → agent → MCP tool → model.
5. A **migration playbook** for moving existing LangGraph / LangChain
   agents under this gateway with three lines of instrumentation code.

## How the day is structured

| Time | Module | Length |
| --- | --- | --- |
| 09:00 | **M0** — Setup and architecture briefing | 30 min |
| 09:30 | **M1** — AI Gateway foundations | 75 min |
| 10:45 | Break | 15 min |
| 11:00 | **M2** — FinOps, observability, and security | 60 min |
| 12:00 | Lunch | 60 min |
| 13:00 | **M3** — Model Context Protocol through the gateway | 45 min |
| 13:45 | **M4** — Agent Framework: local, cloud, hybrid | 75 min |
| 15:00 | Break | 15 min |
| 15:15 | **M5** — Evaluation and local red teaming | 45 min |
| 16:00 | **M6** — OpenTelemetry end-to-end | 45 min |
| 16:45 | Wrap-up and Q&A | 15 min |

## Service residency reality (Indonesia Central, May 2026)

This workshop deploys to **Azure Indonesia Central (IDC)** with a
cross-region fan-out to **Southeast Asia (SEA / Singapore)** for the
services that are not yet in IDC. The decision matrix below is the same
one you will use when planning a real deployment in any region with
partial service coverage.

| Capability | Available in IDC | Available in SEA | Strategy used here |
| --- | --- | --- | --- |
| APIM Developer / Premium **classic** | ✅ | ✅ | Workshop = Developer. Prod = Premium classic, or self-hosted gateway on customer AKS. |
| APIM **v2** tiers | ❌ | ✅ | Concept only — not deployable in IDC. |
| AKS | ✅ | ✅ | Workshop AKS in IDC. Agents, MCP servers, SLM, self-hosted Content Safety. |
| Azure AI Search | ✅ Basic only (no semantic ranker) | ✅ all features | Cosmos DB vector + semantic reranker (Preview) as the in-IDC workaround. |
| Cosmos DB vector + semantic reranker (Preview) | ✅ | ✅ | In-IDC reranking option. |
| Azure OpenAI | ❌ | ✅ | Cloud-for-dev only. On-prem path = self-hosted SLM in AKS. |
| Foundry Hosted Agents | ❌ | ✅ | Optional demo — not in IDC. |
| Content Safety **API** | ❌ | ✅ | Cloud-only. See M2 for the container path. |
| Content Safety **container** | ✅ (on AKS) | ✅ | The in-IDC path for content scanning. |

:::tip
The residency story in this workshop is universal — every region with
partial Azure coverage runs into the same trade-offs. Substitute "IDC"
with your target region and the architecture decisions carry over.
:::

## Two architectures, side by side

```mermaid
flowchart TB
    subgraph WS["WORKSHOP / DEV — Indonesia Central (Azure today)"]
        direction TB
        APIM_W["APIM Developer (classic)<br/>• llm-token-limit<br/>• llm-emit-token-metric<br/>• llm-semantic-cache-lookup/store<br/>• llm-content-safety (cloud)<br/>• load-balancer with priority groups"]
        AKS_W["AKS — Cilium + Azure Linux<br/>• Agent (MAF Python 1.3 GA)<br/>• MCP server<br/>• Self-hosted SLM (Phi-4-mini, CPU)<br/>• Content Safety container (CPU)<br/>• KV CSI secrets"]
        DATA_W["AI Search Basic · Cosmos · KV · App Insights"]
        APIM_W --- AKS_W --- DATA_W
    end

    subgraph PROD["ON-PREM / IN-COUNTRY PROD — Customer DC / Azure IDC (target)"]
        direction TB
        APIM_P["APIM Premium classic<br/><i>OR</i><br/>APIM self-hosted gateway<br/>on customer AKS"]
        AKS_P["AKS — Cilium + Azure Linux<br/>• Agent (MAF .NET / Python)<br/>• MCP server pods<br/>• Self-hosted SLM on GPU<br/>• Content Safety on GPU<br/>• KV CSI secrets"]
        DATA_P["AI Search Basic <i>OR</i> Cosmos+rerank<br/><i>OR</i> on-prem pgvector"]
        APIM_P --- AKS_P --- DATA_P
    end

    subgraph SEA["Southeast Asia — Singapore"]
        direction TB
        AOAI["AOAI (gpt-5-mini, embedding-3-large)<br/>Foundry Hosted Agents (Preview)<br/>Content Safety API"]
    end

    WS -.->|cross-region, dev only| SEA
    PROD x-.-x|managed cloud AOAI does NOT<br/>carry to on-prem prod| SEA

    classDef dev fill:#e8f0fe,stroke:#4285f4,stroke-width:1px
    classDef prod fill:#fef7e0,stroke:#f9ab00,stroke-width:1px
    classDef sea fill:#e6f4ea,stroke:#34a853,stroke-width:1px
    class WS dev
    class PROD prod
    class SEA sea
```

## How to use this site

Each module has:

- A short **overview page** with learning goals and prerequisites.
- One or more **hands-on labs** with numbered procedures, copy-pasteable
  commands, and explicit verification steps after every action.
- A **"What you just built"** section that explains the design choices.

You can run every lab on your laptop against the shared workshop landing
zone, or fork [the repo](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop)
and redeploy the whole stack in your own Azure subscription.

:::info Facilitators
If you're running the workshop for others, jump to the
[Facilitator Guide](./90-facilitator-guide/index.md) for landing zone provisioning,
attendee bootstrapping, and policy application. The attendee path
(M0–M6) assumes the landing zone is already up and you've handed each
attendee a printed connection slip.
:::

Ready? Start with [M0 — Setup](./intro/setup).
