---
title: 1.1 — Walk through the AI-gateway policies
sidebar_position: 2
---

# M1.1 — Walk through the AI-gateway policies

## What you will accomplish

In this 55-minute hands-on module you will:

- Read the **policy XML** your facilitator already applied to the
  gateway — line by line, so you can reuse the same XML in production.
- Verify the **`llm-token-limit`** policy by triggering a 429.
- Verify the **semantic cache** by replaying an identical prompt.
- Verify the **priority load balancer** by reading the `.model` field.
- Verify **header-based routing** between AOAI and the self-hosted SLM.

Everything is verified with `curl` against your APIM gateway. You do not
need to register backends or paste policy XML yourself — your facilitator
did that on the shared APIM. See the
[Facilitator Guide](../facilitator-guide/apply-policies) if you're
running this on your own subscription.

## Prerequisites

- M0 done — you can `curl` the gateway and get a completion back.
- `APIM_GATEWAY_URL` and `APIM_KEY` exported in your shell.

The full policy bundle that's applied to the gateway is in
[`policies/workshop-llm-policy.xml`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/workshop-llm-policy.xml).
Each fragment has been **schema-validated** against the May 2026
Microsoft Learn reference.

Admins setting this up themselves: see the
[Facilitator Guide](../90-facilitator-guide/apply-policies.md).

## Step 1 — Read the token-limit policy

```xml
<llm-token-limit
    counter-key="@(context.Subscription.Id)"
    tokens-per-minute="500"
    estimate-prompt-tokens="false"
    tokens-consumed-header-name="x-tokens-consumed"
    remaining-tokens-header-name="x-tokens-remaining" />
```

What each attribute does:

- `counter-key` — what to bucket by. `context.Subscription.Id` means
  each attendee key gets its own quota.
- `tokens-per-minute="500"` — sliding-window budget per counter key.
- `estimate-prompt-tokens="false"` — don't pre-charge; count the actual
  response. Faster, less accurate at edge.
- `tokens-*-header-name` — APIM injects these response headers so
  callers can self-throttle.

### Verify with curl

```bash
curl -sS -i \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hi."}]}' \
  | grep -i "x-tokens-"
```

**Expected output**

```
x-tokens-consumed: 18
x-tokens-remaining: 482
```

To trigger the **429**, hit the gateway in a loop:

```bash
for i in $(seq 1 30); do
  curl -sS -o /dev/null -w "%{http_code}\n" \
    "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
    -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
    -H "x-auth-mode: anonymous" \
    -H "Content-Type: application/json" \
    -d '{"messages":[{"role":"user","content":"Write a 200-word essay."}]}'
done | sort | uniq -c
```

You should see a mix of `200` and `429` responses once the budget is
exhausted. Wait one minute — the window slides, and you can send again.

:::note Classic vs v2 algorithm
APIM **Classic** uses a sliding-window algorithm; **v2 tiers** use a
token-bucket. The same `tokens-per-minute=500` setting behaves slightly
differently across tiers — useful to know when a customer asks why their
numbers don't match
([source](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy)).
:::

## Step 2 — Read the semantic cache pair

The cache uses an embedding backend to vector-compare incoming prompts
against recent ones. The inbound side does lookup; the outbound side
stores the response.

```xml
<!-- inbound -->
<llm-semantic-cache-lookup
    score-threshold="0.05"
    embeddings-backend-id="embeddings-backend"
    embeddings-backend-auth="system-assigned">
    <vary-by>@(context.Subscription.Id)</vary-by>
</llm-semantic-cache-lookup>
```

```xml
<!-- outbound -->
<llm-semantic-cache-store duration="60" />
```

What each attribute does:

- `score-threshold="0.05"` — cosine similarity cutoff. Lower = stricter.
- `embeddings-backend-id` + `embeddings-backend-auth` — the policy
  schema only accepts `system-assigned` here. Your facilitator set this
  up.
- `<vary-by>` — partition the cache by subscription ID so attendees
  don't share cache entries.
- `duration="60"` — TTL on cached responses in seconds.

### Verify

Send the same prompt twice. The first request takes ~800 ms; the second
~40 ms.

```bash
prompt='{"messages":[{"role":"user","content":"What is the capital of Indonesia?"}]}'

# First call — populates the cache
time curl -sS -o /dev/null \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "Content-Type: application/json" \
  -d "$prompt"

# Second call — should hit the cache
time curl -sS -o /dev/null \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "Content-Type: application/json" \
  -d "$prompt"
```

:::warning Mandatory: `embeddings-backend-auth="system-assigned"`
The cache policy only accepts `system-assigned` for the embeddings
backend auth — no other value is allowed by the schema
([source](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-lookup-policy#attributes)).
This is the kind of constraint that doesn't show up until you have
[debugged it](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-lookup-policy#attributes) on a customer call — keep it in your back pocket.
:::

## Step 3 — Read the header-based routing

```xml
<choose>
    <when condition="@(context.Request.Headers.GetValueOrDefault("x-model-tier","premium") == "cheap")">
        <set-backend-service backend-id="slm-phi4" />
    </when>
    <otherwise>
        <set-backend-service backend-id="aoai-sea" />
    </otherwise>
</choose>
```

A `<choose>` block with `<when>`/`<otherwise>` is the APIM idiom for
"if/else". `backend-id` is the APIM **backend** the request gets routed
to — `slm-phi4` is the self-hosted Phi-4-mini on AKS, `aoai-sea` is the
managed AOAI in Singapore.

### Verify

```bash
# Premium tier → AOAI
curl -sS \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "x-model-tier: premium" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Identify yourself in one sentence."}]}' \
  | jq -r '.choices[0].message.content, .model'

# Cheap tier → self-hosted Phi-4
curl -sS \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "x-model-tier: cheap" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Identify yourself in one sentence."}]}' \
  | jq -r '.choices[0].message.content, .model'
```

The `.model` field tells you which backend served the request.

## Step 4 — Priority-based load balancing with failover

The gateway is also wired up with a **backend pool** that fails over
from AOAI to the SLM when the primary backend is unreachable. APIM
Backend Pools live in the
[`backends` API](https://learn.microsoft.com/azure/api-management/backends).

You can't see the failover from the data plane directly — the policy
routes to `aoai-pool` and APIM picks the priority-1 backend (`aoai-sea`)
unless it's unhealthy, in which case priority-2 (`slm-phi4`) takes over.
Your facilitator will demo the failover live; the policy XML is in
[`policies/load-balancer-priority.xml`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/load-balancer-priority.xml).

## Step 5 — Verify every policy with one script

The repo ships a verifier at
[`scripts/verify-policies.sh`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/scripts/verify-policies.sh).
Run it after Steps 1–4 to confirm every applied policy is doing its job.
The script reads `APIM_GATEWAY_URL` and `APIM_KEY` from your environment
(both come from your handout — no Terraform state required).

```bash
./scripts/verify-policies.sh
```

**Expected output**

```
✓ Step 3 — llm-token-limit: x-tokens-consumed header present
✓ Step 3 — llm-token-limit: 429 observed after burst
✓ Step 4 — semantic-cache: 2nd request was < half of first
✓ Step 6 — header routing: premium → gpt-5-mini ; cheap → phi-4-mini-instruct
- Step 1.5 — API resource check skipped (set RG and APIM_NAME to enable)
- Step 2   — Backend MI check skipped (set RG and APIM_NAME to enable)

All policy checks passed (2 admin-only checks skipped).
```

The dashes (`-`) are admin-only checks that are skipped on your laptop —
that's expected. If any line shows `✗`, flag your facilitator.

## What the gateway runs for you

Every request you send through `${APIM_GATEWAY_URL}/openai/...`:

1. **Authenticates** — JWT validation kicks in unless you pass
   `x-auth-mode: anonymous` (you'll add real auth in M2).
2. **Caches** — checks the semantic cache; identical prompts return in ~40 ms.
3. **Counts tokens** — per-subscription quota with a 429 past budget.
4. **Routes** — by header to either a managed cloud model or a
   self-hosted SLM.
5. **Fails over** — automatically when the primary backend is unreachable.
6. **Emits telemetry** — 5-dimension token metrics into App Insights
   (you'll dashboard this in M2).

Without the gateway, every one of those features lives in your application
code. With it, you can ship 30 apps and only worry about prompts.

## Reference

- All policy fragments: [`policies/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/policies)
- [APIM `llm-token-limit` policy](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy)
- [APIM `llm-semantic-cache-lookup` policy](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-lookup-policy)
- [APIM `llm-semantic-cache-store` policy](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-store-policy)
- [APIM backend pools](https://learn.microsoft.com/azure/api-management/backends)
- Admin steps to apply these policies: [Facilitator Guide → Apply policies](../90-facilitator-guide/apply-policies.md)

## Next

[M2 — FinOps + Observability + Security](../finops-observability-security/intro)
