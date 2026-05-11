---
title: 0.1 — Setup and first connectivity
sidebar_position: 1
---

# M0.1 — Setup and first connectivity

## What you will accomplish

In this 15-minute module you will:

- Connect to the shared workshop landing zone.
- Switch into your personal Kubernetes namespace.
- Send your first authenticated request through the AI Gateway.
- Install the Python stack used in every subsequent module.

## Prerequisites

Before you start, make sure each command below prints a version number.

```bash
az version --query '"azure-cli"' -o tsv         # ≥ 2.61
kubectl version --client --output=yaml | head -2 # ≥ 1.30
python --version                                 # ≥ 3.10
node --version                                   # ≥ 20 (for the docs site only)
```

If anything is missing, install:
[Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli),
[kubectl](https://kubernetes.io/docs/tasks/tools/),
[Python 3.13](https://www.python.org/downloads/),
[Node 20](https://nodejs.org/).

### Required Azure permissions

Your Azure identity needs these roles on the workshop resource group to
complete every lab end-to-end. The facilitator has already granted them
to attendees of the shared workshop. If you are running this on your
own subscription, grant them to yourself first.

| Role | Scope | Why |
| --- | --- | --- |
| **Contributor** | Workshop resource group | Manage APIM, AKS, AOAI, Cosmos, AI Search, KV, Storage |
| **Role Based Access Control Administrator** | Workshop resource group | Grant the APIM managed identity access to AOAI / Content Safety (M1.1 Step 2, M2 Step 4) |
| Default user role | Microsoft Entra tenant | Register OAuth client apps for M2 (JWT) and M3 (MCP). Most tenants allow this by default ([`policies/authorizationPolicy.defaultUserRolePermissions.allowedToCreateApps`](https://learn.microsoft.com/graph/api/resources/authorizationpolicy)) |

To grant the first two to yourself on your own RG:

```bash
ME=$(az ad signed-in-user show --query id -o tsv)
RG_SCOPE="/subscriptions/<your-sub-id>/resourceGroups/<your-rg>"

az role assignment create --assignee-object-id "$ME" \
  --assignee-principal-type User \
  --role "Contributor" --scope "$RG_SCOPE"

az role assignment create --assignee-object-id "$ME" \
  --assignee-principal-type User \
  --role "Role Based Access Control Administrator" --scope "$RG_SCOPE"
```

:::note Why a constrained RBAC Administrator and not Owner
`Role Based Access Control Administrator` is the modern, scope-limited
role that grants only `Microsoft.Authorization/roleAssignments/write`
([reference](https://learn.microsoft.com/azure/role-based-access-control/built-in-roles#role-based-access-control-administrator)).
Use it instead of `Owner` so attendees can't escalate each other.
:::

## Step 1 — Sign in to Azure

```bash
az login
az account set --subscription <workshop-subscription-id>
az account show --query "{name:name, sub:id, tenant:tenantId}" -o table
```

**Expected output**

```
Name                                   Sub                                    Tenant
-------------------------------------  -------------------------------------  ------------------------------------
<your-workshop-account>                xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx   xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
```

Real values are unique to your subscription — keep them out of screenshots
and chat threads.

## Step 2 — Get your attendee handout

Each attendee has a number from `01` to `10`. Your facilitator gives you
yours. Replace `03` below with your own.

```bash
cd hybrid-ai-platform-workshop
./scripts/print-attendee-handout.sh 03
```

The handout prints your APIM subscription key, your Kubernetes namespace
(`attendee-03`), and the shared backend endpoints. Treat the key like a
password — do not paste it into Slack or commit it to Git.

## Step 3 — Connect to the shared AKS cluster

```bash
RG=rg-aigw-workshop
AKS=$(terraform -chdir=infra output -raw aks_name)

az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing
kubectl config set-context --current --namespace=attendee-03
kubectl get nodes -o wide
```

**Expected output** — three or more `Ready` Azure Linux nodes:

```
NAME                              STATUS   ROLES    AGE   VERSION    OS-IMAGE
aks-system-xxxxxxxx-vmss000000    Ready    <none>   1d    v1.31.4    Azure Linux 3.0
aks-system-xxxxxxxx-vmss000001    Ready    <none>   1d    v1.31.4    Azure Linux 3.0
```

Verify your namespace already has the workshop bootstrap resources:

```bash
kubectl get serviceaccount,secretproviderclass,secret
```

You should see `agent-sa`, `azure-kv-shared`, and `apim-credentials`. If
any are missing, the facilitator has not yet run
`scripts/bootstrap-attendees.sh` — flag it and skip ahead.

## Step 4 — Send your first gateway request

This is the moment of truth: a request from your laptop → APIM in
Indonesia Central → Azure OpenAI in Southeast Asia → back to your laptop.

```bash
APIM_GATEWAY=$(terraform -chdir=infra output -raw apim_gateway_url)
APIM_KEY=$(kubectl get secret apim-credentials \
  -o jsonpath='{.data.subscription-key}' | base64 -d)

curl -sS \
  "${APIM_GATEWAY}/openai/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Reply in one short sentence."}]}' \
  | jq -r '.choices[0].message.content'
```

**Expected output** — any single short sentence from the model. Example:

```
The sky is blue because of Rayleigh scattering.
```

### What just happened?

1. Your request landed on APIM Developer in Indonesia Central.
2. The `llm-token-limit` policy checked your remaining per-minute quota.
3. The `llm-emit-token-metric` policy queued a metric in Application
   Insights tagged with your subscription ID.
4. APIM proxied to the AOAI account in Singapore over the Azure backbone.
5. AOAI returned a completion; APIM emitted final token counts; the
   response came back to you.

Open Application Insights (the facilitator shares the URL) and run:

```kusto
customMetrics
| where name == "Total Tokens"
| where timestamp > ago(5m)
| project timestamp, customDimensions, value
| take 10
```

You should see your own request, tagged with your `Subscription ID`.

## Step 5 — Install the Python stack

Every subsequent module uses the same pinned set of packages. Smoke-tested
on Python 3.13 on May 10 2026.

```bash
python -m venv .venv
source .venv/bin/activate

pip install \
  'agent-framework==1.3.*' \
  'langchain==1.2.15' \
  'langchain-core==1.2.31' \
  'langchain-openai==1.1.14' \
  'wrapt<2' \
  --pre microsoft-agents-a365-observability-extensions-langchain \
  --pre microsoft-agents-a365-observability-extensions-agent-framework \
  'azure-monitor-opentelemetry'
```

:::warning Pin the LangChain trio
The A365 LangChain instrumentor breaks against `langchain-core >= 1.3.0a`
with `wrap_function_wrapper() got an unexpected keyword argument 'module'`.
The pins above are verified working.
:::

## Verify the install

```python
import agent_framework
import microsoft_agents_a365.observability.core
import microsoft_agents_a365.observability.extensions.langchain
import microsoft_agents_a365.observability.extensions.agentframework
import langchain
print("agent_framework", agent_framework.__version__)
print("langchain", langchain.__version__)
```

**Expected output**

```
agent_framework 1.3.0
langchain 1.2.15
```

## Next

[M0.2 — Architecture briefing](./architecture-reality-check)
