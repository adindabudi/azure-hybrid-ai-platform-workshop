---
title: Apply the AI-gateway policies
sidebar_position: 4
---

# Apply the AI-gateway policies

The hands-on lab pages in M1–M3 walk attendees through the **policy
fragments** and have them verify behavior with `curl`. Attendees do not
have permission to register backends, assign roles, or paste XML into
the APIM portal — **you** do those steps once, here.

Run everything in this guide before the workshop starts.

## Recommended path: one script, ~2 minutes

Steps 1–7 below used to be manual portal-paste work. They're now wrapped
in a single idempotent script:

```bash
./scripts/apply-apim-policies.sh
```

That covers the **default workshop bundle**: AOAI API import, MI role
grants, all four backends, the priority pool, the AOAI **circuit
breaker** (production-grade, MS Learn requirement), the App Insights
diagnostic with `metrics: true`, and the policy XML push. The rest of
this page documents what the script does so you can reason about it,
extend it, or run individual steps by hand.

Optional flags weave in additional patterns from
[`docs/01-gateway-foundations/enterprise-patterns.md`](../gateway-foundations/enterprise-patterns):

```bash
# Default workshop bundle + chargeback quota + PII mask
./scripts/apply-apim-policies.sh --with-quota --with-pii-mask

# Add Content Safety backend (cloud path)
./scripts/apply-apim-policies.sh --with-content-safety

# Add immutable audit trail to Event Hubs (BFSI compliance)
EH_NAMESPACE=eh-audit EH_HUB_NAME=apim-audit \
EH_CONNSTR='Endpoint=sb://...;EntityPath=apim-audit' \
./scripts/apply-apim-policies.sh --with-audit
```

`--dry-run` prints every command without executing.

After the script returns, jump to [Verify everything is green](#verify-everything-is-green)
to confirm. The manual steps below remain as the **reference of what
the script does** in case anything fails or you need to extend it.

## One-time setup

```bash
export RG=rg-aigw-workshop
export APIM=$(terraform -chdir=infra output -raw apim_name)
export APIM_GATEWAY=$(terraform -chdir=infra output -raw apim_gateway_url)
export AOAI_ENDPOINT=$(terraform -chdir=infra output -raw aoai_endpoint)
export AOAI=$(echo "$AOAI_ENDPOINT" | sed 's|https://||; s|\..*||')
export TENANT=$(az account show --query tenantId -o tsv)

APIM_MI=$(az apim show -g "$RG" -n "$APIM" --query "identity.principalId" -o tsv)
AOAI_ID=$(az cognitiveservices account show -g "$RG" -n "$AOAI" --query id -o tsv)
```

## M1 — Reference: what `apply-apim-policies.sh` does, step by step

Everything in this M1 section is what the **script does for you**.
Read it to understand the moving parts; only run the commands manually
if the script can't (e.g. you're applying to an APIM the Terraform
module didn't create).

### 1. Import the AOAI OpenAPI spec into APIM

```bash
curl -sS -o /tmp/aoai.json \
  "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"

AOAI_HOST=$(echo "$AOAI_ENDPOINT" | sed 's|https://||; s|/$||')
python - <<PY
import json
spec = json.load(open("/tmp/aoai.json"))
spec["servers"] = [{
    "url": "https://${AOAI_HOST}/openai",
    "variables": {"endpoint": {"default": "${AOAI_HOST}"}}
}]
json.dump(spec, open("/tmp/aoai.json", "w"))
PY

az apim api import \
  -g "$RG" --service-name "$APIM" \
  --api-id openai \
  --display-name "Azure OpenAI" \
  --path openai \
  --specification-format OpenApiJson \
  --specification-path /tmp/aoai.json \
  --protocols https
```

### 2. Grant the APIM managed identity access to AOAI

```bash
az role assignment create \
  --assignee-object-id "$APIM_MI" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope "$AOAI_ID"
```

### 3. Register the AOAI + embeddings backends

The `az apim backend` subcommand doesn't exist; backends are
created via the management API. Both backends use APIM's system-assigned
managed identity to call AOAI — no key in the policy or named value.

```bash
APIM_ID=$(az apim show -g "$RG" -n "$APIM" --query id -o tsv)

az rest --method put \
  --url "https://management.azure.com${APIM_ID}/backends/aoai-sea?api-version=2024-05-01" \
  --body "{\"properties\":{\"url\":\"${AOAI_ENDPOINT}/openai\",\"protocol\":\"http\",\"credentials\":{\"managedIdentity\":{\"resource\":\"https://cognitiveservices.azure.com\"}}}}"

az rest --method put \
  --url "https://management.azure.com${APIM_ID}/backends/embeddings-backend?api-version=2024-05-01" \
  --body "{\"properties\":{\"url\":\"${AOAI_ENDPOINT}/openai/deployments/text-embedding-3-large\",\"protocol\":\"http\",\"credentials\":{\"managedIdentity\":{\"resource\":\"https://cognitiveservices.azure.com\"}}}}"
```

### 4. Register the self-hosted SLM backend

Assumes you've deployed Phi-4-mini-instruct as
`service/slm-phi4` in namespace `slm` (the workshop's pre-flight ships
a manifest; deploy yours separately if needed).

```bash
kubectl annotate svc slm-phi4 -n slm \
  service.beta.kubernetes.io/azure-load-balancer-internal=true --overwrite

# Wait for the internal LB IP
kubectl get svc slm-phi4 -n slm -w
# Ctrl-C once EXTERNAL-IP shows a 10.40.x.x address

SLM_IP=$(kubectl get svc slm-phi4 -n slm \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}')

az rest --method put \
  --url "https://management.azure.com${APIM_ID}/backends/slm-phi4?api-version=2024-05-01" \
  --body "{\"properties\":{\"url\":\"http://${SLM_IP}:8000/v1\",\"protocol\":\"http\"}}"
```

### 5. Backend pool with priority + failover

Pools require `type=Pool` and the inner `pool.services[].id` must point
to the backend resource path (`/backends/<name>`):

```bash
az rest --method put \
  --url "https://management.azure.com${APIM_ID}/backends/aoai-pool?api-version=2024-05-01" \
  --body '{"properties":{"type":"Pool","pool":{"services":[{"id":"/backends/aoai-sea","priority":1,"weight":100},{"id":"/backends/slm-phi4","priority":2,"weight":100}]}}}'
```

### 6. Wire the App Insights diagnostic on the openai API (required for `llm-emit-token-metric`)

The `<llm-emit-token-metric>` policy is silent if the API doesn't have
an `applicationinsights` diagnostic with `metrics: true`. Without this
step, attendees will see an empty result when they run the M0.1 KQL
query against `customMetrics` even though the policy is in place
([MS Learn — Emit custom metrics](https://learn.microsoft.com/azure/api-management/api-management-howto-app-insights#emit-custom-metrics)).

The Azure CLI `az apim` group doesn't expose this property directly,
so call the management API:

```bash
APIM_ID=$(az apim show -g "$RG" -n "$APIM" --query id -o tsv)

cat > /tmp/diag.json <<JSON
{
  "properties": {
    "loggerId": "${APIM_ID}/loggers/appi-logger",
    "sampling": { "samplingType": "fixed", "percentage": 100 },
    "alwaysLog": "allErrors",
    "logClientIp": true,
    "metrics": true,
    "verbosity": "information",
    "httpCorrelationProtocol": "W3C",
    "frontend": {
      "request":  { "headers": [], "body": { "bytes": 0 } },
      "response": { "headers": [], "body": { "bytes": 0 } }
    },
    "backend": {
      "request":  { "headers": [], "body": { "bytes": 0 } },
      "response": { "headers": [], "body": { "bytes": 0 } }
    }
  }
}
JSON

az rest --method put \
  --url "https://management.azure.com${APIM_ID}/apis/openai/diagnostics/applicationinsights?api-version=2024-05-01" \
  --body @/tmp/diag.json \
  --query '{name:name, loggerId:properties.loggerId, metrics:properties.metrics}' -o jsonc
```

Expected output:

```json
{
  "loggerId": ".../loggers/appi-logger",
  "metrics": true,
  "name": "applicationinsights"
}
```

After the policy is pasted (next step) and the first attendee request
flows through, you can confirm metrics are landing:

```bash
APPI_APPID=$(az resource show \
  -g "$RG" -n appi-aigw-$(echo "$APIM" | awk -F- '{print $NF}') \
  --resource-type Microsoft.Insights/components \
  --query 'properties.AppId' -o tsv)

az rest --method post \
  --url "https://api.applicationinsights.io/v1/apps/${APPI_APPID}/query" \
  --resource "https://api.applicationinsights.io" \
  --body '{"query":"customMetrics | where name == \"Total Tokens\" | where timestamp > ago(15m) | take 5"}' \
  --query 'tables[0].rows | length(@)'
```

A non-zero number means metrics are flowing. Custom-metrics ingestion
latency is ~1 minute.

### 7. Paste the M1 + M2 policy bundle

Open the [APIM portal](https://portal.azure.com) → your APIM → **APIs** →
**Azure OpenAI** → **Design** → **All operations** → **Inbound
processing** → `</>`. Paste the contents of
[`policies/workshop-llm-policy.xml`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/workshop-llm-policy.xml).

This bundle includes:

- `validate-jwt` (gated on `x-auth-mode` header — anonymous in M1, JWT
  required in M2).
- `llm-content-safety` against the `content-safety-sea` backend
  (M2.4 — see "Content safety" below).
- `llm-semantic-cache-lookup` + `llm-semantic-cache-store` (M1.3).
- `rate-limit-by-key` (M2.5).
- `llm-token-limit` (M1.1).
- `llm-emit-token-metric` with 5 chargeback dimensions (M2.1).
- Header-based routing via `x-model-tier` (M1.5).

Click **Save**.

## M2 — Content safety (pick one path)

:::caution Content Safety entitlement
The default workshop Terraform **does not** create a Content Safety
account — many Internal / MCAP / trial subscriptions lack the
entitlement (see comment block in
[`infra/modules/aoai-singapore/main.tf`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/infra/modules/aoai-singapore/main.tf)).
The M2 docs' verifier (`curl ... jailbreak → 403`) will return **200**
on a workshop deployed without one of the paths below. Decide before
the workshop whether you'll skip M2 Step 4's verification or enable
one of these paths.
:::

### Path A — Cloud Content Safety resource

Requires a Content Safety entitlement on your subscription. Create the
resource yourself (or un-comment the CS block in the module and
re-apply), then point `apply-apim-policies.sh` at it:

```bash
# 1. Create or identify an existing Content Safety resource
CS_NAME=cs-aigw-sea-${SUFFIX}   # match your convention
az cognitiveservices account create \
  -g "$RG" -n "$CS_NAME" -l southeastasia \
  --kind ContentSafety --sku S0 --yes
CS_ID=$(az cognitiveservices account show -g "$RG" -n "$CS_NAME" --query id -o tsv)
CS_ENDPOINT=$(az cognitiveservices account show --ids "$CS_ID" --query properties.endpoint -o tsv)

# 2. Grant APIM MI access
az role assignment create \
  --assignee-object-id "$APIM_MI" \
  --assignee-principal-type ServicePrincipal \
  --role "Cognitive Services User" \
  --scope "$CS_ID"

# 3. Register the backend (manual)
APIM_ID=$(az apim show -g "$RG" -n "$APIM" --query id -o tsv)
az rest --method put \
  --url "https://management.azure.com${APIM_ID}/backends/content-safety-sea?api-version=2024-05-01" \
  --body "{\"properties\":{\"url\":\"${CS_ENDPOINT}\",\"protocol\":\"http\",\"credentials\":{\"managedIdentity\":{\"resource\":\"https://cognitiveservices.azure.com\"}}}}"

# 4. OR — let the automation script do steps 2-3 for you
CONTENT_SAFETY_NAME="$CS_NAME" ./scripts/apply-apim-policies.sh --with-content-safety
```

### Path B — Content Safety container on AKS (in-region)

Required when prompt data must not leave the primary region. Container
constraints (preview, billing-metered, amd64, 25.5 GB, GPU for prod) are
documented in
[`apps/content-safety-cpu/README.md`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/apps/content-safety-cpu/README.md).

```bash
kubectl create namespace content-safety
kubectl apply -n content-safety -f apps/content-safety-cpu/content-safety-cpu.yaml
kubectl edit secret content-safety-billing -n content-safety
# Set billing endpoint + key from your Content Safety S0 resource

SVC_IP=$(kubectl get svc -n content-safety content-safety \
  -o jsonpath='{.spec.clusterIP}')

az apim nv create -g "$RG" --service-name "$APIM" \
  --named-value-id content-safety-host --display-name content-safety-host \
  --value "http://${SVC_IP}:5000"

az apim nv create -g "$RG" --service-name "$APIM" \
  --named-value-id content-safety-key --display-name content-safety-key \
  --secret true --value "<your-content-safety-api-key>"
```

Swap the `<llm-content-safety>` block in the policy bundle for the
contents of
[`policies/llm-content-safety-selfhosted.xml`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/llm-content-safety-selfhosted.xml).

## M2 — JWT app registration

```bash
APP_ID=$(az ad app create \
  --display-name "aigw-workshop-client" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

az apim nv create -g "$RG" --service-name "$APIM" \
  --named-value-id aad-tenant-id --display-name aad-tenant-id \
  --value "$TENANT"
az apim nv create -g "$RG" --service-name "$APIM" \
  --named-value-id aad-app-id --display-name aad-app-id \
  --value "$APP_ID"
```

The policy bundle's `<validate-jwt>` references `{{aad-tenant-id}}` and
`{{aad-app-id}}` — once these named values are set, JWT validation kicks
in for any request that doesn't pass `x-auth-mode: anonymous`.

Tell attendees the workshop accepts anonymous traffic when they add the
header. In production you'd remove the `<choose>` wrapper.

## Container images — populate the ACR (once per workshop)

The workshop manifests (`apps/mcp-customer-tool/`, `apps/litellm-comparison/`,
`apps/content-safety-cpu/`) all reference `${ACR_LOGIN_SERVER}/...` so AKS
pulls from the workshop ACR via the kubelet identity's `AcrPull` role.
Three images must be present before any attendee deploys.

```bash
ACR_NAME=$(az acr list -g "$RG" --query "[0].name" -o tsv)
ACR_LOGIN_SERVER=$(az acr list -g "$RG" --query "[0].loginServer" -o tsv)
echo "Populating $ACR_LOGIN_SERVER ..."
```

### 1. Build `mcp-customer-tool:1.0` from source

ACR Tasks (`az acr build`) is not available in every region (e.g. it
fails in `indonesiacentral` with `NoRegisteredProviderFound`). If your
ACR is in a supported region, use ACR Tasks — no local Docker needed:

```bash
az acr build \
  --registry "$ACR_NAME" \
  --image mcp-customer-tool:1.0 \
  --image mcp-customer-tool:latest \
  apps/mcp-customer-tool
```

If `az acr build` returns `NoRegisteredProviderFound` for your region,
fall back to `docker buildx`:

```bash
az acr login --name "$ACR_NAME"
docker buildx build --platform linux/amd64 \
  -t "${ACR_LOGIN_SERVER}/mcp-customer-tool:1.0" \
  -t "${ACR_LOGIN_SERVER}/mcp-customer-tool:latest" \
  --push apps/mcp-customer-tool
```

### 2. Mirror the two public images into ACR

`az acr import` runs server-side, so neither command needs Docker:

```bash
az acr import --name "$ACR_NAME" --force \
  --source ghcr.io/berriai/litellm:main-stable \
  --image litellm:main-stable

az acr import --name "$ACR_NAME" --force \
  --source mcr.microsoft.com/azure-cognitive-services/contentsafety/text-analyze:latest \
  --image contentsafety-text-analyze:latest
```

### 3. Verify

```bash
az acr repository list -n "$ACR_NAME" -o table
# Expect: contentsafety-text-analyze, litellm, mcp-customer-tool

for r in mcp-customer-tool litellm contentsafety-text-analyze; do
  echo "=== $r ==="
  az acr repository show-tags -n "$ACR_NAME" --repository "$r" -o tsv
done
```

### 4. Smoke-test the pulls from AKS

Validates the kubelet identity's `AcrPull` binding really works end to
end. The content-safety image is ~8.8 GB — first pull can take 2–3 min.

```bash
NS=attendee-01
kubectl delete pod -n "$NS" pull-test-mcp pull-test-litellm pull-test-cs \
  --ignore-not-found=true

cat <<EOF | kubectl apply -n "$NS" -f -
apiVersion: v1
kind: Pod
metadata: { name: pull-test-mcp }
spec:
  restartPolicy: Never
  containers:
  - { name: c, image: "${ACR_LOGIN_SERVER}/mcp-customer-tool:1.0",
      command: ["/bin/sh","-c","echo pull-ok; sleep 3"] }
---
apiVersion: v1
kind: Pod
metadata: { name: pull-test-litellm }
spec:
  restartPolicy: Never
  containers:
  - { name: c, image: "${ACR_LOGIN_SERVER}/litellm:main-stable",
      command: ["/bin/sh","-c","echo pull-ok; sleep 3"] }
---
apiVersion: v1
kind: Pod
metadata: { name: pull-test-cs }
spec:
  restartPolicy: Never
  containers:
  - { name: c, image: "${ACR_LOGIN_SERVER}/contentsafety-text-analyze:latest",
      command: ["/bin/sh","-c","echo pull-ok; sleep 3"] }
EOF

kubectl wait -n "$NS" --for=jsonpath='{.status.phase}'=Running \
  pod/pull-test-mcp pod/pull-test-litellm pod/pull-test-cs --timeout=600s

kubectl delete pod -n "$NS" pull-test-mcp pull-test-litellm pull-test-cs
```

If any pod stays in `ImagePullBackOff`, double-check the kubelet
identity has `AcrPull` on the ACR scope — the Terraform in `infra/`
sets this; re-run `terraform apply` if it's missing.

## M3 — MCP (per attendee)

### Register MCP backends behind APIM

Attendees deploy their own MCP server in their namespace — see
[M3](../mcp-secure-tool-access/intro) Step 1, which only needs namespace
RBAC. Registering the MCP backend behind APIM is admin work; do it
once per attendee namespace **after attendees have deployed their MCP
server**, so the loop skips namespaces that don't have one yet:

```bash
for NN in $(seq -f '%02g' 1 10); do
  NS="attendee-${NN}"
  # Skip namespaces where attendee hasn't deployed yet
  kubectl get svc mcp-customer-tool -n "$NS" >/dev/null 2>&1 || continue

  kubectl annotate svc mcp-customer-tool -n "$NS" \
    service.beta.kubernetes.io/azure-load-balancer-internal=true --overwrite

  # Wait up to 60s for the internal LB to allocate an IP
  for _ in {1..12}; do
    MCP_LB=$(kubectl get svc mcp-customer-tool -n "$NS" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null)
    [[ -n "$MCP_LB" ]] && break
    sleep 5
  done
  if [[ -z "$MCP_LB" ]]; then
    echo "!! $NS: internal LB IP not assigned within 60s, skipping"
    continue
  fi

  APIM_ID=$(az apim show -g "$RG" -n "$APIM" --query id -o tsv)
  az rest --method put \
    --url "https://management.azure.com${APIM_ID}/backends/mcp-${NS}?api-version=2024-05-01" \
    --body "{\"properties\":{\"url\":\"http://${MCP_LB}:8765\",\"protocol\":\"http\"}}"
  az apim api create -g "$RG" --service-name "$APIM" \
    --api-id "mcp-${NS}" --display-name "MCP: ${NS}" \
    --path "mcp/${NS}" --protocols https \
    --service-url "http://${MCP_LB}:8765"
done
```

Apply
[`policies/mcp-oauth-pkce.xml`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/blob/main/policies/mcp-oauth-pkce.xml)
to each MCP API and register an OAuth client app per the M3 docs (admin
content folded in here).

## Verify everything is green

Run the verifier with admin env vars set so it also runs the
control-plane checks:

```bash
export APIM_GATEWAY_URL="$APIM_GATEWAY"
export APIM_KEY=$(az apim subscription show -g "$RG" --service-name "$APIM" \
  --sid attendee-01 --query primaryKey -o tsv)
export APIM_NAME="$APIM"
export LOG_ANALYTICS_WORKSPACE_ID=$(terraform -chdir=infra output \
  -raw log_analytics_workspace_id)

./scripts/verify-policies.sh --m2
```

All checks should be green. If anything is red, re-read the
corresponding section above.

## Reference

- All policy XML: [`policies/`](https://github.com/adindabudi/azure-hybrid-ai-platform-workshop/tree/main/policies)
- [APIM AI-gateway policy reference](https://learn.microsoft.com/azure/api-management/api-management-policies#ai-gateway)
- [APIM backends API](https://learn.microsoft.com/azure/api-management/backends)
- [APIM named values](https://learn.microsoft.com/azure/api-management/api-management-howto-properties)
