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

You can run this lab on **any of three shells**. Pick one and stick with
it for the day — mixing breaks `kubectl` (see the warning below).

| Track | Shell | When to pick it |
| --- | --- | --- |
| **A — Linux / macOS** | `bash` / `zsh` | You're on Linux or a Mac. |
| **B — WSL Ubuntu on Windows** | `bash` inside WSL | You have WSL installed. Cleanest Windows path. |
| **C — Windows native** | PowerShell 7 (or Windows PowerShell 5.1) | No WSL, no admin rights to install one. |

Every command in M0–M6 is shown in **bash first**. Where Windows-native
syntax differs (env vars, `curl`), a PowerShell block is shown right
below.

### Verify your tools

**Track A / B (bash):**

```bash
az version --query '"azure-cli"' -o tsv          # ≥ 2.61
kubectl version --client --output=yaml | head -2 # ≥ 1.30
python --version                                  # ≥ 3.10
node --version                                    # ≥ 20 (docs site only)
```

**Track C (PowerShell):**

```powershell
az version --query '"azure-cli"' -o tsv          # ≥ 2.61
kubectl version --client --output=yaml | Select-Object -First 2
python --version
node --version
```

### Install what's missing — **none of these require admin rights**

**Azure CLI** ([install-azure-cli on MS Learn](https://learn.microsoft.com/cli/azure/install-azure-cli)):

| Track | Command | Admin? |
| --- | --- | --- |
| A (macOS) | `brew install azure-cli` | no |
| A (Ubuntu/Debian) / B (WSL) | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` | `sudo` only (no Windows admin) |
| C (Windows native) | `winget install -e --id Microsoft.AzureCLI --scope user` | **no** (user scope) |

**kubectl** via `az aks install-cli` — drops the binary into your
**user profile**, no admin needed
([az aks install-cli MS Learn](https://learn.microsoft.com/cli/azure/aks#az-aks-install-cli)):

**Track A / B (bash):**

```bash
az aks install-cli
# Installs to ~/.azure-kubectl/kubectl
# Add to PATH if needed:
echo 'export PATH="$HOME/.azure-kubectl:$PATH"' >> ~/.bashrc
source ~/.bashrc
kubectl version --client | head -1
```

**Track C (PowerShell):**

```powershell
az aks install-cli
# Installs to %USERPROFILE%\.azure-kubectl\kubectl.exe — no admin needed.
# Add to user PATH (persists across sessions):
[Environment]::SetEnvironmentVariable(
    "PATH",
    [Environment]::GetEnvironmentVariable("PATH","User") + ";$env:USERPROFILE\.azure-kubectl",
    "User"
)
# Reopen PowerShell, then:
kubectl version --client
```

If you can't install Azure CLI at all (locked-down laptop), fall back
to the browser-based [Azure Cloud Shell](https://shell.azure.com) — it
ships with `az`, `kubectl`, and `curl` already wired up.

:::warning Don't mix Windows-native `az` with WSL `kubectl`
WSL inherits the Windows `PATH`, so if you installed Azure CLI on
Windows (Track C) and `kubectl` inside WSL (Track B), `az.exe` writes
`kubeconfig` to `C:\Users\<you>\.kube\config` and your WSL `kubectl`
reads `/home/<you>/.kube/config` — two different files. The result is
`kubectl config set-context` returning *"no current context is set"*
even though `az aks get-credentials` succeeded. **Pick one track and
install both `az` and `kubectl` inside it.** Step 4a below recovers if
you've already hit this.
:::

:::info Syntax conventions for the rest of the workshop
M0 (this page) shows every command in both **bash** and **PowerShell**.
M1–M6 default to bash. If you're on **Track C (Windows native)**,
translate three things as you go:

| bash | PowerShell |
| --- | --- |
| `export FOO=bar` | `$env:FOO = "bar"` |
| `"${FOO}"` inside a string | `"$env:FOO"` |
| `curl ...` (in pipelines) | `curl.exe ...` (PowerShell's `curl` is `Invoke-WebRequest`) |
| `\` line-continuation | `` ` `` (backtick) |

Everything else (`az`, `kubectl`, `jq` if installed, `python`,
`docker`) has the same syntax on both shells.
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

Export the two values every lab needs.

**Track A / B (bash):**

```bash
export APIM_GATEWAY_URL="https://apim-aigw-xxx.azure-api.net"
export APIM_KEY="..."
export NAMESPACE="attendee-03"
```

**Track C (PowerShell):**

```powershell
$env:APIM_GATEWAY_URL = "https://apim-aigw-xxx.azure-api.net"
$env:APIM_KEY        = "..."
$env:NAMESPACE       = "attendee-03"
```

:::caution Sensitive
`APIM_KEY` is your subscription key — treat it like a password. Do not
paste it into Slack, email, or screenshots; do not commit it to git.
:::

## Step 4 — Connect to the shared AKS cluster

Your handout lists `RESOURCE_GROUP` and `AKS_NAME` — substitute them
below. The resource group is the same for every attendee; the AKS name
has a random suffix (e.g. `aks-aigw-7f2a`).

**Track A / B (bash):**

```bash
RG="rg-aigw-workshop"       # from your handout
AKS="aks-aigw-xxx"          # from your handout — replace `xxx` with your real suffix
```

**Track C (PowerShell):**

```powershell
$RG  = "rg-aigw-workshop"
$AKS = "aks-aigw-xxx"
```

:::tip Handout doesn't show the full AKS name?
List the clusters your account can see in the workshop RG:

```bash
az aks list -g "$RG" --query "[].name" -o tsv      # bash
az aks list -g $RG --query "[].name" -o tsv        # PowerShell
```
:::

### 4a — (WSL only) make sure `az` and `kubectl` share the same kubeconfig

**Skip this entire section if you're on Track A (Linux/macOS) or
Track C (Windows native).** It only applies to Track B (WSL) attendees
who accidentally installed Azure CLI on Windows instead of inside WSL.

Run inside your WSL shell:

```bash
which az kubectl
```

| Output | Meaning | Action |
| --- | --- | --- |
| Both end in `/usr/bin/...` | Same OS — you're fine | Skip to **4b** |
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

**Track A / B (bash):**

```bash
az aks get-credentials --resource-group "$RG" --name "$AKS" --overwrite-existing
```

**Track C (PowerShell):**

```powershell
az aks get-credentials --resource-group $RG --name $AKS --overwrite-existing
```

Expected last line — **the path here must match where `kubectl` reads from**:

```text
Merged "aks-aigw-xxx" as current context in /home/<you>/.kube/config   # bash on Linux/WSL
Merged "aks-aigw-xxx" as current context in C:\Users\<you>\.kube\config # PowerShell on Windows
```

If you see `C:\Users\...\.kube\config` while running **WSL bash**, you
skipped 4a — fix it now or `kubectl` will keep saying *"no current
context is set"*.

### 4c — Pin your namespace and verify

**Track A / B (bash):**

```bash
kubectl config current-context           # must print aks-aigw-xxx
kubectl config set-context --current --namespace="$NAMESPACE"
kubectl get serviceaccount,secretproviderclass,secret
```

**Track C (PowerShell):**

```powershell
kubectl config current-context                          # must print aks-aigw-xxx
kubectl config set-context --current --namespace=$env:NAMESPACE
kubectl get serviceaccount,secretproviderclass,secret
```

You should see `agent-sa`, `azure-kv-shared`, and `apim-credentials`. If
any are missing, flag your facilitator — they haven't run the attendee
bootstrap yet.

:::caution Still getting `error: no current context is set` or `connection refused 127.0.0.1:8080`?
Both errors mean `kubectl` can't find a populated kubeconfig. Diagnose:

```bash
# bash
echo "KUBECONFIG=${KUBECONFIG:-<unset, defaults to ~/.kube/config>}"
kubectl config view --minify        # should show a "current-context" line
ls -la ~/.kube/config 2>/dev/null
ls -la /mnt/c/Users/*/.kube/config 2>/dev/null
```

```powershell
# PowerShell
"KUBECONFIG=$($env:KUBECONFIG ?? '<unset, defaults to ~/.kube/config>')"
kubectl config view --minify
Get-Item $env:USERPROFILE\.kube\config -ErrorAction SilentlyContinue
```

If a Windows-path config file exists but your `KUBECONFIG` is unset
inside WSL, you're hitting the WSL split-kubeconfig issue — go back to
**4a Option B**. Background:
[AKS — Config file isn't available when connecting](https://learn.microsoft.com/troubleshoot/azure/azure-kubernetes/connectivity/config-file-is-not-available-when-connecting).
:::

## Step 5 — Send your first gateway request

This is the moment of truth: a request from your laptop → APIM in
Indonesia Central → Azure OpenAI in Southeast Asia → back to your laptop.

**Track A / B (bash):**

```bash
curl -sS \
  "${APIM_GATEWAY_URL}/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" \
  -H "Ocp-Apim-Subscription-Key: ${APIM_KEY}" \
  -H "x-auth-mode: anonymous" \
  -H "Content-Type: application/json" \
  -d '{"messages":[{"role":"user","content":"Reply in one short sentence."}]}' \
  | jq -r '.choices[0].message.content'
```

**Track C (PowerShell)** — use `curl.exe` explicitly (PowerShell's
`curl` is an alias for `Invoke-WebRequest` with a different syntax;
real `curl.exe` ships with Windows 10 1803+):

```powershell
$response = curl.exe -sS `
  "$env:APIM_GATEWAY_URL/openai/deployments/gpt-5-mini/chat/completions?api-version=2024-10-21" `
  -H "Ocp-Apim-Subscription-Key: $env:APIM_KEY" `
  -H "x-auth-mode: anonymous" `
  -H "Content-Type: application/json" `
  -d '{"messages":[{"role":"user","content":"Reply in one short sentence."}]}'

($response | ConvertFrom-Json).choices[0].message.content
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

**Track A / B (bash):**

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

**Track C (PowerShell):**

```powershell
python -m venv .venv
.\.venv\Scripts\Activate.ps1
# If you get "running scripts is disabled on this system", run once
# in the same session — does not require admin, only affects this PS process:
#   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass

pip install `
  'agent-framework==1.3.*' `
  'langchain==1.2.15' `
  'langchain-core==1.2.31' `
  'langchain-openai==1.1.14' `
  'wrapt<2' `
  --pre microsoft-agents-a365-observability-extensions-langchain `
  --pre microsoft-agents-a365-observability-extensions-agent-framework `
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
