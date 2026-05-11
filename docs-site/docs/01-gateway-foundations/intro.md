---
title: 1.0 — Why a gateway?
sidebar_position: 1
---

# M1.0 — Why a gateway?

## What you will accomplish

This 20-minute conceptual module sets up the rest of M1. By the end you
will be able to answer:

- Why does an AI platform need a gateway between the application and
  the model?
- Where does Azure API Management fit relative to LiteLLM and direct
  SDK access?
- What does "AI Gateway" actually mean in terms of policies?

If you only have an hour, skim this page and jump straight to
[M1.1 — Hands-on policies](./policies).

## The before/after

**Before — direct SDK access:**

```
┌────────────┐         ┌──────────────┐
│ App / Bot  │────────▶│ Azure OpenAI │
└────────────┘         └──────────────┘
```

Every concern — auth, rate limits, content scanning, cost tracking,
fall-back to a cheaper model, key rotation — lives in the application.
If you have 30 applications, you have 30 copies of that logic.

**After — gateway-fronted:**

```
┌────────────┐    ┌─────────┐    ┌──────────────┐
│ App / Bot  │───▶│  APIM   │───▶│ Azure OpenAI │
└────────────┘    │         │    └──────────────┘
                  │         │    ┌──────────────┐
                  │         │───▶│ Self-hosted  │
                  │         │    │  SLM on AKS  │
                  └─────────┘    └──────────────┘
                       │
                       ▼
                  ┌─────────┐
                  │ App Ins │
                  └─────────┘
```

Cross-cutting concerns move into APIM as policies, applications shrink to
business logic, and you get one place to enforce limits, swap models, and
emit cost telemetry.

## What ships in the box

Azure API Management has a dedicated set of AI-gateway policies. We use
all of them in this workshop. The full reference is in the
[AI gateway capabilities](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
doc.

| Policy | What it does | Workshop module |
| --- | --- | --- |
| [`llm-token-limit`](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy) | Sliding-window token quota per subscription/key/header | M1.1 |
| [`llm-emit-token-metric`](https://learn.microsoft.com/azure/api-management/llm-emit-token-metric-policy) | Emits token counts to App Insights with up to 5 dimensions | M2.1 |
| [`llm-semantic-cache-lookup`](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-lookup-policy) | Vector-based cache lookup before calling the model | M1.3 |
| [`llm-semantic-cache-store`](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-store-policy) | Cache the response on the way back | M1.3 |
| [`llm-content-safety`](https://learn.microsoft.com/azure/api-management/llm-content-safety-policy) | Block harmful prompts via Content Safety | M2.5 |
| [Backend pool with priority](https://learn.microsoft.com/azure/api-management/backends) | LB/failover across multiple model backends | M1.2 |

Plus the general-purpose policies you already know — `validate-jwt`,
`rate-limit-by-key`, `set-backend-service`, `choose` — which work the
same with AI APIs as with any other.

## How APIM compares to alternatives

You will get this question. Have an honest answer ready.

| Option | Where it runs | SLA | Policy coverage | Best for |
| --- | --- | --- | --- | --- |
| Direct AOAI SDK | Anywhere | AOAI SLA | None | Local dev, prototypes |
| [LiteLLM](https://github.com/BerriAI/litellm) | Anywhere (Python proxy) | None (OSS) | Lightweight rate limit, cost log | OSS-first shops, multi-cloud |
| APIM Developer (this workshop) | Azure region | None | Full LLM policy engine | Dev / staging |
| APIM Premium classic | Azure region (incl. IDC) | 99.95–99.99% | Full LLM policy engine | Production where v2 isn't available |
| APIM Premium v2 | v2 regions | 99.99% | Full | Production in v2 regions, multi-tenant |
| APIM self-hosted gateway | Customer AKS | Customer-managed | Full | On-prem, air-gapped, custom networking |

The LLM policies (`llm-*`) are **supported in classic, v2, consumption,
self-hosted, and workspace gateways alike**, per the
[policy reference](https://learn.microsoft.com/azure/api-management/api-management-policies#ai-gateway).
This means the policy XML you write today against APIM Developer drops
cleanly into a Premium classic, a v2, or a self-hosted gateway later —
no rewrite.

## The Microsoft sample we lean on

Two reference architectures inform the lab in M1.2:

- [`Azure-Samples/openai-apim-lb`](https://github.com/Azure-Samples/openai-apim-lb) — smart load balancer with priority groups.
- [`Azure-Samples/AI-Gateway`](https://github.com/Azure-Samples/AI-Gateway) — comprehensive recipe collection for the LLM policies.

You don't need to read them before continuing; we lift the right pieces
inline in M1.1–M1.3.

## Next

[M1.1 — Hands-on policies](./policies)
