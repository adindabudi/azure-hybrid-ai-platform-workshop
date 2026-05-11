---
title: Wrap-up and hardening checklist
sidebar_position: 1
---

# Wrap-up

## What you shipped today

If you completed M0–M6, you now have:

- ✅ APIM as an AI Gateway with token limits, semantic cache, tier
  routing, priority-based failover, and 5-dimension token telemetry.
- ✅ Entra ID JWT auth + Content Safety scanning (cloud and/or
  container path).
- ✅ A multi-runtime MAF agent that switches between AOAI, self-hosted
  SLM, LiteLLM, and Foundry Local with one env var.
- ✅ A 3-agent Workflow with checkpointing.
- ✅ MCP servers behind the gateway with OAuth 2.0 / PKCE.
- ✅ Five Foundry evaluators in CI + a local PyRIT red-team scan.
- ✅ One OpenTelemetry trace per request, end-to-end, in App Insights
  and (optionally) Aspire / Grafana / Splunk.

That's the entire shape of a production AI platform. The rest of the
journey is hardening.

## Production hardening checklist

Use this in your customer's first design review. Each item is a real
decision they need to make, with a workshop reference.

### Gateway tier

- [ ] Pick APIM tier:
  - **Premium classic** (~USD 3K+/month per region) for an SLA-backed
    managed gateway in regions without v2.
  - **Premium v2** in regions that support it.
  - **Self-hosted gateway** on customer AKS for on-prem / air-gapped.
  - Reference: [M0.2](./00-intro/architecture-reality-check)

### Content safety

- [ ] Pick a path:
  - **Path A** — cloud Content Safety resource for managed simplicity.
  - **Path B** — Content Safety container in AKS for in-region data
    residency. Requires GPU node pool (T4/L4 minimum) for production.
  - Reference: [M2 Step 4](./02-finops-observability-security/intro)

### Model backend

- [ ] Choose between managed (Azure OpenAI / Foundry) and self-hosted
  SLM:
  - Self-hosted SLM sized per the workshop benchmark — 1× A10 sustains
    ~137 t/s on Phi-4-mini-instruct Q4_K_M.
  - vLLM / llama.cpp / TensorRT-LLM choice depends on GPU class.
  - Reference: [M1.5–1.6](./01-gateway-foundations/policies)

### Vector store

- [ ] Pick a path for retrieval:
  - **Azure AI Search Basic** if available — accept the lack of
    semantic ranker in some regions.
  - **Cosmos DB vector + semantic reranker (Preview)** as the in-region
    workaround.
  - **On-prem pgvector / Qdrant / Elasticsearch** for fully self-hosted.

### Observability

- [ ] Application Insights or customer-owned backend (Splunk, Datadog,
  Elastic) via OTLP.
- [ ] Define the chargeback granularity — usually subscription + model
  is enough, but team-level needs custom dimensions.
- [ ] Reference: [M6](./06-otel-end-to-end/intro)

### Identity

- [ ] Workload identity on AKS (already enabled in the workshop
  cluster).
- [ ] One App Registration per consumer team.
- [ ] One APIM **product** per team, narrow OAuth scopes per product.

### Network

- [ ] Private endpoints on Cosmos, Key Vault, Storage, ACR.
- [ ] APIM Premium with VNet integration for on-prem connectivity.
- [ ] Cilium NetworkPolicy for in-cluster east-west traffic.

### Evaluation gate in CI

- [ ] Failing PRs on `intent_resolution` < 0.80 or `tool_call_accuracy`
  < 0.75.
- [ ] Local PyRIT scan on each release tag.
- [ ] Reference: [M5](./05-evaluation-redteam/intro)

## Migration playbook for existing LangChain / LangGraph agents

You don't have to rewrite. Three options, in order of effort:

1. **Add the A365 LangChain instrumentor** (3 lines, [M4.1](./04-agent-framework/migrate-from-langgraph))
   and front the existing chain with APIM. You get observability and
   gateway policies; the chain code is untouched.
2. **Replace the LLM client only** — keep your LangGraph state machine,
   swap the LLM client for an `OpenAIChatClient` pointed at APIM. You
   gain backend portability (AOAI / SLM / LiteLLM) without rewriting
   the orchestration.
3. **Full rewrite to MAF Workflow** — only when you need typed graphs,
   checkpointing, .NET parity, or the Foundry Hosted runtime.

## Tear-down

To return the workshop subscription to a clean state:

```bash
cd hybrid-ai-platform-workshop/infra
terraform destroy -var-file=env/workshop.tfvars
```

This removes all 90+ resources except the resource group itself
(which was created out-of-band on purpose). The destroy completes in
~15 minutes; APIM Developer is the long pole.

## Take it further

- Fork the [repo](https://github.com/adindaputra/hybrid-ai-platform-workshop)
  and redeploy the whole stack in your own Azure subscription. Every
  module is reproducible end-to-end.
- Run it again with `attendee_count=1` for the worst-case
  presenter-only path.
- Substitute `location = "westeurope"` (or any region with full
  service coverage) and watch which modules simplify.
- Adapt the policy XML to your customer's specific guardrails.

## Reference

- [Workshop repo](https://github.com/adindaputra/hybrid-ai-platform-workshop)
- [APIM AI gateway capabilities](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- [Microsoft Agent Framework docs](https://learn.microsoft.com/agent-framework/)
- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)

Thanks for spending the day with us.
