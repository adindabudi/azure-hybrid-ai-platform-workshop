---
title: 1.1 — Apply the AI-gateway policies
sidebar_position: 2
---

# M1.1 — Apply the AI-gateway policies

## What you will accomplish

In this 55-minute hands-on module you will:

- Onboard **Azure OpenAI** (Singapore) as an APIM backend with managed
  identity auth.
- Onboard a **self-hosted Phi-4-mini SLM** (AKS) as a second backend.
- Apply the `llm-token-limit` policy and verify the 429 path.
- Apply the **semantic cache** pair and verify the cache hit.
- Configure a **priority-based load balancer** and kill the primary key
  to verify automatic failover.
- Route by header to either model with one `<choose>` block.

## Prerequisites

- M0 completed (you can `curl` the gateway and get a completion back).
- `az` and `kubectl` configured against the shared workshop landing zone.
- Your APIM subscription key in `apim-credentials` secret.

The full XML for every policy in this module is in
[`policies/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/policies)
in the repo. Each fragment has been **schema-validated offline** against
the May 2026 Microsoft Learn reference.

## Step 1 — Verify your APIM instance

Set environment variables once at the top — every subsequent command
uses them.

```bash
export RG=rg-aigw-workshop
export APIM=$(terraform -chdir=infra output -raw apim_name)
export APIM_GATEWAY=$(terraform -chdir=infra output -raw apim_gateway_url)
export APIM_KEY=$(kubectl get secret apim-credentials \
  -o jsonpath='{.data.subscription-key}' | base64 -d)

az apim show -g "$RG" -n "$APIM" \
  --query "{state: provisioningState, sku: sku.name}" -o table
```

**Expected output**

```
State      Sku
---------  ---------
Succeeded  Developer
```

## Step 1.5 — Create the OpenAI API in APIM

Policies attach to APIs. Before applying anything, register the AOAI
deployment as an APIM **API resource**. Microsoft publishes the
OpenAPI specification for the AOAI inference data plane on GitHub; we
import that, pointed at our AOAI Singapore endpoint.

```bash
# Download the official 2024-10-21 GA spec
curl -sS -o /tmp/aoai.json \
  "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"

# Patch the spec to point at YOUR AOAI account (the spec ships with a
# placeholder). The Python one-liner edits the JSON in place.
AOAI_HOST=$(terraform -chdir=infra output -raw aoai_endpoint | sed 's|https://||; s|/$||')
python - <<PY
import json
spec = json.load(open("/tmp/aoai.json"))
spec["servers"] = [{
    "url": "https://${AOAI_HOST}/openai",
    "variables": {"endpoint": {"default": "${AOAI_HOST}"}}
}]
json.dump(spec, open("/tmp/aoai.json", "w"))
PY

# Import as an APIM API. Path "openai" matches the path the AOAI SDK uses.
az apim api import \
  -g "$RG" --service-name "$APIM" \
  --api-id openai \
  --display-name "Azure OpenAI" \
  --path openai \
  --specification-format OpenApiJson \
  --specification-path /tmp/aoai.json \
  --protocols https
```

### Verify

```bash
az apim api show -g "$RG" --service-name "$APIM" --api-id openai \
  --query "{name: displayName, path: path, protocols: protocols}" -o table
```

**Expected output**

```
Name          Path    Protocols
------------  ------  ---------
Azure OpenAI  openai  ['https']
```

Source: [Import an Azure OpenAI API as a REST API](https://learn.microsoft.com/azure/api-management/azure-openai-api-from-specification).

## Step 2 — Register the AOAI backend with managed identity

The `llm-*` policies require the backend to authenticate via the APIM
system-assigned identity, not an API key
([source](https://learn.microsoft.com/azure/api-management/llm-content-safety-policy#prerequisites)).

```bash
# 1. Get the APIM managed identity object ID
APIM_MI=$(az apim show -g "$RG" -n "$APIM" \
  --query "identity.principalId" -o tsv)

# 2. Get the AOAI resource ID
AOAI=$(terraform -chdir=infra output -raw aoai_endpoint \
  | sed 's|https://||; s|\..*||')
AOAI_ID=$(az cognitiveservices account show \
  --resource-group "$RG" --name "$AOAI" --query id -o tsv)

# 3. Grant Cognitive Services User on the AOAI account
az role assignment create \
  --assignee-object-id "$APIM_MI" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope "$AOAI_ID"

# 4. Create the APIM backend pointing at AOAI
AOAI_ENDPOINT=$(terraform -chdir=infra output -raw aoai_endpoint)
az apim backend create \
  --resource-group "$RG" --service-name "$APIM" \
  --backend-id aoai-sea \
  --url "$AOAI_ENDPOINT/openai" \
  --protocol http \
  --credentials-managed-identity-resource "https://cognitiveservices.azure.com" 2>/dev/null \
  || echo "Backend already exists, continuing"
```

**Verify**

```bash
az apim backend show -g "$RG" --service-name "$APIM" --backend-id aoai-sea \
  --query "{url:url, auth:credentials.managedIdentity}" -o table
```

You should see the endpoint URL and the audience
`https://cognitiveservices.azure.com`.

## Step 3 — Apply `llm-token-limit`

Open the [APIM portal](https://portal.azure.com), navigate to your APIM →
APIs → choose the OpenAI API → click **Design** → **Inbound processing**.
Paste:

```xml
<llm-token-limit
    counter-key="@(context.Subscription.Id)"
    tokens-per-minute="500"
    estimate-prompt-tokens="false"
    tokens-consumed-header-name="x-tokens-consumed"
    remaining-tokens-header-name="x-tokens-remaining" />
```

Click **Save**.

### Verify

Send one request and observe the headers:

```bash
curl -sS -i \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
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
    "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
    -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
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

## Step 4 — Add the semantic cache

The cache uses an embedding backend to vector-compare incoming prompts
against recent ones. Grant the APIM MI access to the embedding deployment
first (same role assignment scope from Step 2 already covers it because
the embedding lives in the same AOAI account).

Create the embedding backend:

```bash
az apim backend create \
  --resource-group "$RG" --service-name "$APIM" \
  --backend-id embeddings-backend \
  --url "${AOAI_ENDPOINT}/openai/deployments/text-embedding-3-large" \
  --protocol http \
  --credentials-managed-identity-resource "https://cognitiveservices.azure.com" 2>/dev/null \
  || echo "Backend already exists, continuing"
```

In the same **Inbound processing** XML, add **after** the
`<llm-token-limit>` block:

```xml
<llm-semantic-cache-lookup
    score-threshold="0.05"
    embeddings-backend-id="embeddings-backend"
    embeddings-backend-auth="system-assigned">
    <vary-by>@(context.Subscription.Id)</vary-by>
</llm-semantic-cache-lookup>
```

In **Outbound processing**, add:

```xml
<llm-semantic-cache-store duration="60" />
```

Click **Save**.

### Verify

Send the same prompt twice. The first request takes ~800 ms; the second
~40 ms.

```bash
prompt='{"messages":[{"role":"user","content":"What is the capital of Indonesia?"}]}'

# First call — populates the cache
time curl -sS -o /dev/null \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "Content-Type: application/json" \
  -d "$prompt"

# Second call — should hit the cache
time curl -sS -o /dev/null \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "Content-Type: application/json" \
  -d "$prompt"
```

:::warning Mandatory: `embeddings-backend-auth="system-assigned"`
The cache policy only accepts `system-assigned` for the embeddings
backend auth — no other value is allowed by the schema
([source](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-lookup-policy#attributes)).
If you forget the role assignment from Step 2, you'll see `401` errors
from the embedding backend.
:::

## Step 5 — Add the self-hosted SLM backend

The workshop AKS already has a Phi-4-mini-instruct service running at
`http://slm-phi4.slm.svc.cluster.local:8000`. The facilitator deployed it
during pre-flight. Verify:

```bash
kubectl get svc -n slm
```

**Expected output**

```
NAME       TYPE        CLUSTER-IP    EXTERNAL-IP   PORT(S)    AGE
slm-phi4   ClusterIP   10.41.x.x     <none>        8000/TCP   1h
```

To make this reachable from APIM, expose it as a Service of type
`LoadBalancer` with an **internal** annotation, or front it with an
ingress that APIM can reach. For the workshop we use the simpler path
(internal load balancer):

```bash
kubectl annotate svc slm-phi4 -n slm \
  service.beta.kubernetes.io/azure-load-balancer-internal=true \
  --overwrite

# Wait for the IP
kubectl get svc slm-phi4 -n slm -w
# Ctrl-C once EXTERNAL-IP shows a 10.40.x.x address
```

Register the backend:

```bash
SLM_IP=$(kubectl get svc slm-phi4 -n slm \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

az apim backend create \
  --resource-group "$RG" --service-name "$APIM" \
  --backend-id slm-phi4 \
  --url "http://${SLM_IP}:8000/v1" \
  --protocol http
```

## Step 6 — Header-based routing

Add to **Inbound processing**:

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

### Verify

```bash
# Premium tier → AOAI
curl -sS \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-model-tier: premium" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Identify yourself in one sentence."}]}' \
  | jq -r '.choices[0].message.content, .model'

# Cheap tier → self-hosted Phi-4
curl -sS \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-model-tier: cheap" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Identify yourself in one sentence."}]}' \
  | jq -r '.choices[0].message.content, .model'
```

The `.model` field tells you which backend served the request.

## Step 7 — Priority-based load balancing with failover

Create a **backend pool** that includes both backends with different
priorities. APIM Backend Pools is part of the
[`backends` API](https://learn.microsoft.com/azure/api-management/backends).

```bash
az apim backend create \
  --resource-group "$RG" --service-name "$APIM" \
  --backend-id aoai-pool \
  --type Pool \
  --url "https://placeholder" \
  --pool '{"services":[{"id":"/backends/aoai-sea","priority":1,"weight":100},{"id":"/backends/slm-phi4","priority":2,"weight":100}]}'
```

Replace your routing `<choose>` with:

```xml
<set-backend-service backend-id="aoai-pool" />
```

### Verify failover

Temporarily break the AOAI backend by setting an invalid override URL:

```bash
az apim backend update \
  --resource-group "$RG" --service-name "$APIM" \
  --backend-id aoai-sea \
  --url "https://invalid-host-do-not-exist.example.com"

# Should still get a response, served by the SLM
curl -sS \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Say hi."}]}' \
  | jq -r '.choices[0].message.content'

# Restore
az apim backend update \
  --resource-group "$RG" --service-name "$APIM" \
  --backend-id aoai-sea \
  --url "${AOAI_ENDPOINT}/openai"
```

## Step 8 — Verify every policy with one script

The repo ships a verifier at
[`scripts/verify-policies.sh`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/scripts/verify-policies.sh).
Run it after Steps 1–7 to confirm every applied policy is doing its job.
The script reads `APIM_GATEWAY_URL` and `APIM_KEY` from your environment
(both come from the handout your facilitator gave you — no Terraform
state required).

```bash
export APIM_GATEWAY_URL="https://aigw-xxx.azure-api.net"   # from handout
export APIM_KEY="..."                                       # from handout
./scripts/verify-policies.sh
```

**Expected output**

```
✓ Step 1.5 — API resource 'openai' present
✓ Step 2  — Backend 'aoai-sea' with managed identity
✓ Step 3  — llm-token-limit: x-tokens-consumed header present
✓ Step 3  — llm-token-limit: 429 after exceeding budget
✓ Step 4  — semantic-cache: second identical request < 200 ms
✓ Step 6  — header routing: x-model-tier=premium → aoai-sea
✓ Step 6  — header routing: x-model-tier=cheap → slm-phi4
✓ Step 7  — backend pool: failover to SLM when primary down

8/8 policies verified.
```

If any line shows `✗`, re-read the corresponding step and re-apply the
policy in the APIM portal.

## What you just built

A single OpenAI-compatible endpoint that:

1. **Caches** repeat requests and returns them in ~40 ms.
2. **Counts tokens** per subscription and rejects with `429` past the
   budget.
3. **Routes** by header to either a managed cloud model or a self-hosted
   SLM.
4. **Fails over** automatically when the primary backend is unreachable.

Without the gateway, every one of those features lives in your application
code. Now you can ship 30 apps and only worry about prompts.

## Reference

- All policy fragments: [`policies/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/policies)
- [APIM `llm-token-limit` policy](https://learn.microsoft.com/azure/api-management/llm-token-limit-policy)
- [APIM `llm-semantic-cache-lookup` policy](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-lookup-policy)
- [APIM `llm-semantic-cache-store` policy](https://learn.microsoft.com/azure/api-management/llm-semantic-cache-store-policy)
- [APIM backend pools](https://learn.microsoft.com/azure/api-management/backends)

## Next

[M2 — FinOps + Observability + Security](../finops-observability-security/intro)
