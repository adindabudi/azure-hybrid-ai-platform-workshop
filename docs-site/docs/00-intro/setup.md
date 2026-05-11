---
title: 0.1 — Setup and first connectivity
sidebar_position: 1
---

# M0.1 — Setup and first connectivity

## What you will accomplish

In this 15-minute module you will:

- Use the printed handout your facilitator gave you to set two env vars.
- Connect to the shared workshop AKS in your personal namespace.
- Send your first authenticated request through the AI Gateway.
- Install the Python stack used in every subsequent module.

:::info Running this on your own subscription?
The attendee path assumes the facilitator has already deployed the
landing zone and handed you a slip of paper. If you're running solo,
follow the [Facilitator Guide](../90-facilitator-guide/index.md) first, then come
back here and pretend you're attendee `01`.
:::

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

:::warning Windows + WSL users — install `az` *inside* WSL
If you're running this lab in WSL, install Azure CLI **in your WSL
distro** (`curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash`),
not the Windows MSI. WSL inherits the Windows `PATH`, so `az.exe` will
silently shadow whatever you intend to use and write `kubeconfig` to
`C:\Users\<you>\.kube\config` — but your WSL `kubectl` reads
`/home/<you>/.kube/config`. The result is `kubectl config set-context`
returning *"no current context is set"* even though `az aks
get-credentials` succeeded. Mixing OS sides is the #1 setup failure for
this workshop. See **Step 4a** below for the recovery path if you've
already hit it.
:::

## Step 1 — Clone the workshop repo

Every subsequent module references files in this repo
(`scripts/verify-policies.sh`, `apps/agent-complaint-triage/agent.py`,
`apps/mcp-customer-tool/deployment.yaml`, etc). Clone it once and
`cd` in — all later commands assume your shell is at the repo root.

```bash
git clone https://github.com/adindabudi/azure-hybrid-ai-platform-workshop.git
cd azure-hybrid-ai-platform-workshop
```

## Step 2 — Sign in to Azure

```bash
az login
az account set --subscription <workshop-subscription-id>
az account show --query "{name:name, sub:id, tenant:tenantId}" -o table
```

The subscription ID comes from your facilitator. You only need
**read** access at the workshop subscription scope — the facilitator
has already provisioned everything.

## Step 3 — Read your handout

Your facilitator hands you a printed slip with values like:

```text
ATTENDEE         attendee-03
NAMESPACE        attendee-03
APIM_GATEWAY_URL https://apim-aigw-xxx.azure-api.net
APIM_KEY         <long random string — treat like a password>
AKS_NAME         aks-aigw-xxx
RESOURCE_GROUP   rg-aigw-workshop
GPT_DEPLOYMENT   gpt-5-mini
EMBEDDING        text-embedding-3-large
COSMOS_ENDPOINT  https://...
SEARCH_ENDPOINT  https://...
KEY_VAULT_URI    https://...
APP_INSIGHTS_CONN_STRING InstrumentationKey=...
```

Export the two values every lab needs:

```bash
export APIM_GATEWAY_URL="https://apim-aigw-xxx.azure-api.net"
export APIM_KEY="..."
export NAMESPACE="attendee-03"
```

:::caution Sensitive
`APIM_KEY` is your subscription key — treat it like a password. Do not
paste it into Slack, email, or screenshots; do not commit it to git.
:::

## Step 4 — Connect to the shared AKS cluster

Your handout lists `RESOURCE_GROUP` and `AKS_NAME` — substitute them
below. The resource group is the same for every attendee; the AKS name
has a random suffix (e.g. `aks-aigw-7f2a`).

```bash
RG="rg-aigw-workshop"       # from your handout
AKS="aks-aigw-xxx"          # from your handout — replace `xxx` with your real suffix
```

:::tip Handout doesn't show the full AKS name?
List the clusters your account can see in the workshop RG:

```bash
az aks list -g "$RG" --query "[].name" -o tsv
```
:::

### 4a — Make sure `az` and `kubectl` share the same kubeconfig

This is the **most common stumbling block on Windows + WSL**, so check
it *before* you call `az aks get-credentials`. Run:

```bash
which az kubectl
```

| Output | Meaning | Action |
| --- | --- | --- |
| Both end in `/usr/bin/...` (or both `.exe`) | Same OS — you're fine | Skip to **4b** |
| `az` ends in `.exe` but `kubectl` does **not** (or vice versa) | You're in WSL but `az` is the Windows installer. They write/read different `kubeconfig` files. | Pick **one** option below, then go to 4b |

**Option A (recommended) — install `az` inside WSL** so both binaries
share `~/.kube/config`
([apt install per MS Learn](https://learn.microsoft.com/cli/azure/install-azure-cli-linux?pivots=apt)):

```bash
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
hash -r
which az            # must now be /usr/bin/az
az login            # re-login inside WSL
```

**Option B (quick) — point WSL `kubectl` at the Windows kubeconfig**
that `az.exe` writes to:

```bash
WIN_USER="$(/mnt/c/Windows/System32/cmd.exe /c 'echo %USERNAME%' 2>/dev/null | tr -d '\r')"
export KUBECONFIG="/mnt/c/Users/${WIN_USER}/.kube/config"
echo "export KUBECONFIG=\"$KUBECONFIG\"" >> ~/.bashrc   # persist for new shells
```

### 4b — Pull the kubeconfig

```bash
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
```

Expected last line — **the path here must match where `kubectl` reads from**:

```text
Merged "aks-aigw-xxx" as current context in /home/<you>/.kube/config
```

If you see `C:\Users\...\.kube\config` instead and `kubectl` is your
WSL Linux binary, you skipped 4a — fix it now or `kubectl` will keep
saying *"no current context is set"*.

### 4c — Pin your namespace and verify

```bash
kubectl config current-context           # must print aks-aigw-xxx
kubectl config set-context --current --namespace="$NAMESPACE"
kubectl get serviceaccount,secretproviderclass,secret
```

You should see `agent-sa`, `azure-kv-shared`, and `apim-credentials`. If
any are missing, flag your facilitator — they haven't run the attendee
bootstrap yet.

:::caution Still getting `error: no current context is set` or `connection refused 127.0.0.1:8080`?
Both errors mean `kubectl` can't find a populated kubeconfig. Diagnose:

```bash
echo "KUBECONFIG=${KUBECONFIG:-<unset, defaults to ~/.kube/config>}"
kubectl config view --minify        # should show a "current-context" line
ls -la ~/.kube/config 2>/dev/null
ls -la /mnt/c/Users/*/.kube/config 2>/dev/null
```

If a Windows-path config file exists but your `KUBECONFIG` is unset,
you're hitting the WSL split-kubeconfig issue — go back to **4a Option B**.
Background:
[AKS — Config file isn't available when connecting](https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/connectivity/config-file-is-not-available-when-connecting).
:::

## Step 5 — Send your first gateway request

This is the moment of truth: a request from your laptop → APIM in
Indonesia Central → Azure OpenAI in Southeast Asia → back to your laptop.

```bash
curl -sS \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
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

If your facilitator gave you `APP_INSIGHTS_CONN_STRING` and granted you
**Log Analytics Reader** on the workspace, you can also query your
request:

```kusto
customMetrics
| where name == "Total Tokens"
| where timestamp > ago(5m)
| project timestamp, customDimensions, value
| take 10
```

You should see your own request, tagged with your `Subscription ID`. If
you don't have reader access, ask your facilitator for a screenshot
during the workshop — it'll come up again in M2.

## Step 6 — Install the Python stack

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
