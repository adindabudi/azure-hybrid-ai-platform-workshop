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

## Crawl-Walk-Run adoption plan {#crawl-walk-run-adoption-plan}

If today's lab is the *complete* picture, your Monday-morning rollout
should be the *first 5%*. The progression below mirrors how Azure
customers in Indonesia have actually moved from "AI proof-of-concept"
to "regulated AI platform" — with each step adding one or two policies
and one or two organisational habits, not a re-platform.

### Crawl (week 1–4) — one team, observability first

**Goal**: ship one internal AI use case behind APIM, with cost and
token telemetry visible from day one.

- Stand up APIM (Developer or Premium-classic) + 1 Azure OpenAI
  deployment in your primary region.
- Apply only **two** policies from this workshop:
  - `llm-emit-token-metric` ([M2 Step 1](../02-finops-observability-security/intro.md))
  - `validate-jwt` ([M2 Step 3](../02-finops-observability-security/intro.md))
- One App Registration for one consumer team. One subscription key.
- One App Insights workbook with the three KQL tiles from M2 Step 2.

**Outcome**: you can answer *"what did AI cost us this week and who
spent it?"* before you talk about adding a second team.

### Walk (month 2–3) — multi-team, safety in line

**Goal**: open the platform to 3–5 teams without losing per-team
control, and put runtime safety in the request path.

- Add `llm-token-limit` + `llm-semantic-cache-lookup` /
  `-store` ([M1.2–M1.3](../01-gateway-foundations/policies.md)).
- Add `llm-content-safety` with Prompt Shields ([M2 Step 4](../02-finops-observability-security/intro.md)).
- One **APIM product per consumer team**; per-product subscription
  keys. Each team gets its own chargeback row in the KQL tile.
- Wire Defender for Cloud — AI threat protection (cloud regions only).
- First MAF agent + Foundry evaluators in CI ([M4](../04-agent-framework/intro.md) + [M5](../05-evaluation-redteam/intro.md)).

**Outcome**: a CISO can read the runtime safety story end-to-end; a
finance partner can read the chargeback story end-to-end; an engineer
can ship a new agent without a security review per release.

### Run (month 4–6) — regulated workloads, residency, regression discipline

**Goal**: pass a real OJK / Permenkes / BI audit and run AI as a
regulated platform service, not as a side project.

- Add `circuit-breaker-aoai`, `load-balancer-priority`, and the
  dual-region (IDC + SEA) routing with `x-data-classification`
  ([M1.4](../01-gateway-foundations/enterprise-patterns.md)).
- Turn on `audit-trail-eventhub` → ADLS Gen2 with immutable storage
  for 7-year retention.
- Add `quota-by-key-monthly` per consumer team.
- Wire the PyRIT scan into the release-tag pipeline; treat any new
  bypass as a release blocker, not a finding.
- Stand up MCP-fronted tools for any agent that touches systems of
  record ([M3](../03-mcp-secure-tool-access/intro.md)).
- Quarterly PTU-vs-PAYG review using the KQL in
  [M2 Step 4.5](../02-finops-observability-security/intro.md#step-45--cost-discipline-turning-the-gateway-into-a-finops-control).

**Outcome**: AI is now a regulated platform service. The auditor
question — *"for every decision, show me the prompt, the version, the
retrieved data, and who called it"* — has a documented, automated
answer.

The full set of policies in [`policies/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/policies)
and the [industry playbooks](../90-industry-playbooks/index.md)
expand each Run-phase item into a concrete artefact.

## Production hardening checklist

Use this in your first production design review. Each item is a real
decision you need to make, with a workshop reference.

### Gateway tier

- [ ] Pick APIM tier:
  - **Premium classic** (~USD 3K+/month per region) for an SLA-backed
    managed gateway in regions without v2.
  - **Premium v2** in regions that support it.
  - **Self-hosted gateway** on customer AKS for on-prem / air-gapped.
  - Reference: [M0.2](../00-intro/architecture-reality-check.md)

### Content safety

- [ ] Pick a path:
  - **Path A** — cloud Content Safety resource for managed simplicity.
  - **Path B** — Content Safety container in AKS for in-region data
    residency. Requires GPU node pool (T4/L4 minimum) for production.
  - Reference: [M2 Step 4](../02-finops-observability-security/intro.md)

### Model backend

- [ ] Choose between managed (Azure OpenAI / Foundry) and self-hosted
  SLM:
  - Self-hosted SLM sized per the workshop benchmark — 1× A10 sustains
    ~137 t/s on Phi-4-mini-instruct Q4_K_M.
  - vLLM / llama.cpp / TensorRT-LLM choice depends on GPU class.
  - Reference: [M1.5–1.6](../01-gateway-foundations/policies.md)

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
- [ ] Reference: [M6](../06-otel-end-to-end/intro.md)

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
- [ ] Reference: [M5](../05-evaluation-redteam/intro.md)

## Migration playbook for existing LangChain / LangGraph agents

You don't have to rewrite. Three options, in order of effort:

1. **Add the A365 LangChain instrumentor** (3 lines, [M4.1](../04-agent-framework/migrate-from-langgraph.md))
   and front the existing chain with APIM. You get observability and
   gateway policies; the chain code is untouched.
2. **Replace the LLM client only** — keep your LangGraph state machine,
   swap the LLM client for an `OpenAIChatCompletionClient` pointed at
   APIM. You gain backend portability (AOAI / SLM / LiteLLM) without
   rewriting the orchestration. (Use the **chat-completion** client,
   not `OpenAIChatClient` — APIM imports only the chat-completions
   surface of the AOAI OpenAPI spec.)
3. **Full rewrite to MAF Workflow** — only when you need typed graphs,
   checkpointing, .NET parity, or the Foundry Hosted runtime.

## Tear-down — do this today if you're self-paced

:::danger Stop the meter
The workshop stack costs **~USD 6–9 per hour** while idle, dominated by
APIM Developer SKU (~USD 0.07/h), AKS system pool + 1× A10 GPU node
(~USD 1.20/h when running), AOAI provisioned tokens, and the App
Insights workspace. A weekend left running = USD 200+ on your bill.

Run `terraform destroy` **the same day** you finish the lab — do not
"come back to it tomorrow". If you're a facilitator running for an
attendee cohort, schedule a calendar reminder for 18:00 local on the
workshop day.
:::

To return the workshop subscription to a clean state:

```bash
cd azure-hybrid-ai-platform-workshop/infra
terraform destroy -var-file=env/workshop.tfvars
```

This removes all 90+ resources except the resource group itself
(which was created out-of-band on purpose). The destroy completes in
~15 minutes; APIM Developer is the long pole — it stays in a
`Deleting` state for ~10 minutes even after `terraform destroy`
returns. If you re-run the workshop within 48 hours, you can usually
`terraform apply` straight on top of the partial deletion and APIM
will reuse the soft-deleted instance instead of waiting out the full
purge window.

Verify nothing is left:

```bash
az resource list -g rg-aigw-workshop --query "[].{name:name, type:type}" -o table
# Expect: empty (or just lingering APIM in Deleting state)
```

If anything other than APIM remains, delete it manually before closing
the laptop.

## Take it further

- Fork the [repo](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop)
  and redeploy the whole stack in your own Azure subscription. Every
  module is reproducible end-to-end.
- Run it again with `attendee_count=1` for the worst-case
  presenter-only path.
- Substitute `location = "westeurope"` (or any region with full
  service coverage) and watch which modules simplify.
- Adapt the policy XML to your own organization's specific guardrails.

## Reference

- [Workshop repo](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop)
- [APIM AI gateway capabilities](https://learn.microsoft.com/azure/api-management/genai-gateway-capabilities)
- [Microsoft Agent Framework docs](https://learn.microsoft.com/agent-framework/)
- [OpenTelemetry GenAI semantic conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/)

Thanks for spending the day with us.
