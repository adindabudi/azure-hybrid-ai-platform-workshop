#!/usr/bin/env bash
# apply-apim-policies.sh — END-TO-END automation of the APIM AI-gateway
# setup that used to be Steps 1-7 of docs/90-facilitator-guide/apply-policies.md.
#
# FACILITATOR-ONLY. Idempotent. Re-runnable.
#
# What it does (in order):
#   1. Imports the AOAI OpenAPI spec into APIM as the `openai` API
#   2. Grants the APIM managed identity `Cognitive Services User` on AOAI
#      (and on Content Safety if --with-content-safety)
#   3. Creates the four backends: aoai-sea, embeddings-backend, slm-phi4,
#      content-safety-sea (last one only with --with-content-safety)
#   4. Creates the priority pool aoai-pool (P1=aoai-sea, P2=slm-phi4)
#   5. Adds CIRCUIT BREAKER to the AOAI backend (5 failures in 1m → trip 5m,
#      honour Retry-After). MS Learn requirement for AOAI.
#   6. Wires the App Insights diagnostic with metrics:true on the openai API
#      (mandatory for llm-emit-token-metric to actually emit)
#   7. PUSHES the policy bundle (policies/workshop-llm-policy.xml) via
#      `az rest` against the management API
#
# Optional flags:
#   --with-content-safety   also create content-safety-sea backend + RBAC
#   --with-audit            also create Event Hub logger + apply
#                           audit-trail-eventhub.xml (requires EH_NAMESPACE,
#                           EH_HUB_NAME env vars)
#   --with-pii-mask         also fold the outbound PII-mask block (one
#                           <send-request> per response to the in-cluster
#                           Presidio orchestrator at apps/presidio-pii)
#                           into the bundle. Requires apps/presidio-pii
#                           to be deployed first; see its README for the
#                           optional Mode B (Presidio + Azure AI Language).
#   --with-quota            also append quota-by-key-monthly.xml inbound
#   --dry-run               print every command, execute none
#
# Required env vars (auto-read from terraform if blank):
#   RG, APIM, AOAI_ENDPOINT, AOAI_NAME
#
# Optional env vars:
#   ATTENDEE_COUNT          number of attendee-NN products to link openai API to.
#                           Falls back to discovering every `attendee-*` product
#                           on the APIM service.
#
# Usage:
#   ./scripts/apply-apim-policies.sh
#   ./scripts/apply-apim-policies.sh --with-content-safety --with-quota
#
# Verify after running:
#   APIM_GATEWAY_URL=... APIM_KEY=... ./scripts/verify-policies.sh --m2

set -euo pipefail

# ---------- arg parsing ----------
WITH_CS=0; WITH_AUDIT=0; WITH_PII=0; WITH_QUOTA=0; DRY=0
for a in "$@"; do
  case "$a" in
    --with-content-safety) WITH_CS=1 ;;
    --with-audit)          WITH_AUDIT=1 ;;
    --with-pii-mask)       WITH_PII=1 ;;
    --with-quota)          WITH_QUOTA=1 ;;
    --dry-run)             DRY=1 ;;
    -h|--help)
      sed -n '2,30p' "$0"; exit 0 ;;
    *) echo "unknown flag: $a"; exit 2 ;;
  esac
done

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INFRA_DIR="$ROOT/infra"
POLICIES_DIR="$ROOT/policies"

# ---------- env ----------
if [[ -z "${RG:-}" || -z "${APIM:-}" || -z "${AOAI_ENDPOINT:-}" ]]; then
  echo "==> Reading Terraform outputs..."
  RG="${RG:-$(terraform -chdir="$INFRA_DIR" output -raw resource_group_name)}"
  APIM="${APIM:-$(terraform -chdir="$INFRA_DIR" output -raw apim_name)}"
  AOAI_ENDPOINT="${AOAI_ENDPOINT:-$(terraform -chdir="$INFRA_DIR" output -raw aoai_endpoint)}"
fi
AOAI_NAME="${AOAI_NAME:-$(echo "$AOAI_ENDPOINT" | sed -E 's|https?://([^.]+)\..*|\1|')}"
SUB_ID=$(az account show --query id -o tsv)
APIM_ID=$(az apim show -g "$RG" -n "$APIM" --query id -o tsv)
APIM_MI=$(az apim show -g "$RG" -n "$APIM" --query identity.principalId -o tsv)
AOAI_ID=$(az cognitiveservices account show -g "$RG" -n "$AOAI_NAME" --query id -o tsv)
AOAI_HOST=$(echo "$AOAI_ENDPOINT" | sed -E 's|https?://||; s|/$||')

run() {
  if (( DRY == 1 )); then
    printf '  [dry-run] %s\n' "$*"
  else
    "$@"
  fi
}

green() { printf '\033[32m✓\033[0m %s\n' "$1"; }
yellow(){ printf '\033[33m!\033[0m %s\n' "$1"; }

API_VER="2024-05-01"
MGMT="https://management.azure.com${APIM_ID}"

echo "==> Subscription : $SUB_ID"
echo "==> RG / APIM    : $RG / $APIM"
echo "==> AOAI         : $AOAI_NAME ($AOAI_ENDPOINT)"
echo "==> Flags        : CS=$WITH_CS  AUDIT=$WITH_AUDIT  PII=$WITH_PII  QUOTA=$WITH_QUOTA  DRY=$DRY"
echo ""

# ============================================================
# Step 1 — Import AOAI OpenAPI spec
# ============================================================
echo "[1/7] Import AOAI OpenAPI spec → API id 'openai'..."
SPEC=/tmp/aoai-spec.json
if (( DRY == 0 )); then
  curl -sS -o "$SPEC" \
    "https://raw.githubusercontent.com/Azure/azure-rest-api-specs/main/specification/cognitiveservices/data-plane/AzureOpenAI/inference/stable/2024-10-21/inference.json"
  python3 - <<PY
import json, os
p="$SPEC"; spec=json.load(open(p))
spec["servers"]=[{"url":"https://${AOAI_HOST}/openai",
                  "variables":{"endpoint":{"default":"${AOAI_HOST}"}}}]
json.dump(spec, open(p,"w"))
PY
fi
run az apim api import -g "$RG" --service-name "$APIM" \
  --api-id openai --display-name 'Azure OpenAI' --path openai \
  --specification-format OpenApiJson --specification-path "$SPEC" \
  --protocols https
green "API 'openai' imported"

# ------------------------------------------------------------
# Step 1.4 — PATCH subscriptionKeyParameterNames so the header
# the Azure OpenAI / azure-ai-evaluation SDKs send by default
# (`api-key`) is the one APIM actually checks. Out-of-the-box
# `az apim api import` sets this to `Ocp-Apim-Subscription-Key`,
# which is APIM's classic default but does NOT match what the
# OpenAI Python SDK / azure-ai-evaluation send. Result:
# every SDK call returns 401 "Access denied due to invalid
# subscription key" until this is patched.
#
# Idempotent: the previous `az apim api import` preserves the
# existing value when the spec doesn't override it, so we read
# first and only PATCH if it's not already `api-key`.
# ------------------------------------------------------------
CURRENT_HEADER=$(az rest --method get \
  --url "${MGMT}/apis/openai?api-version=${API_VER}" \
  --query 'properties.subscriptionKeyParameterNames.header' -o tsv 2>/dev/null || echo "")
if [[ "$CURRENT_HEADER" == "api-key" ]]; then
  green "API 'openai' subscription-key header already set to 'api-key' (skip)"
else
  run az rest --method patch \
    --url "${MGMT}/apis/openai?api-version=${API_VER}" \
    --headers Content-Type=application/json "If-Match=*" \
    --body '{"properties":{"subscriptionKeyParameterNames":{"header":"api-key","query":"subscription-key"}}}' >/dev/null
  green "API 'openai' subscription-key header set to 'api-key' (was '${CURRENT_HEADER}')"
fi

# ------------------------------------------------------------
# Step 1.5 — Link the openai API to every attendee product so
# subscription keys actually authorise it. `az apim api import`
# only creates the API; the subscription key on each attendee
# product is scoped to the product's API list, so without this
# linkage every attendee request returns 401 “invalid subscription
# key”.
# ------------------------------------------------------------
link_api_to_attendee_products() {
  local products attendee_count="${ATTENDEE_COUNT:-}"
  if [[ -n "$attendee_count" ]]; then
    products=$(seq -f 'attendee-%02g' 1 "$attendee_count")
  else
    # Discover every product whose id starts with `attendee-` (matches the
    # naming convention in infra/modules/apim-developer/main.tf).
    products=$(az apim product list -g "$RG" --service-name "$APIM" \
      --query "[?starts_with(name, 'attendee-')].name" -o tsv 2>/dev/null || true)
  fi
  if [[ -z "$products" ]]; then
    yellow "No attendee-* products found — skipping API→product linkage (M0 bootstrap not run yet?)"
    return 0
  fi
  local linked=0
  for product_id in $products; do
    run az rest --method put \
      --url "${MGMT}/products/${product_id}/apis/openai?api-version=${API_VER}" \
      --body '{}' --headers Content-Type=application/json >/dev/null
    linked=$((linked + 1))
  done
  green "openai API linked to ${linked} attendee product(s)"
}
link_api_to_attendee_products

# ============================================================
# Step 2 — RBAC: APIM MI → Cognitive Services User on AOAI
# ============================================================
echo "[2/7] Grant APIM MI access to AOAI..."
EXISTING=$(az role assignment list --assignee-object-id "$APIM_MI" --scope "$AOAI_ID" \
  --query "[?roleDefinitionName=='Cognitive Services User'] | length(@)" -o tsv 2>/dev/null || echo 0)
if [[ "$EXISTING" == "0" ]]; then
  run az role assignment create --assignee-object-id "$APIM_MI" \
    --assignee-principal-type ServicePrincipal \
    --role 'Cognitive Services User' --scope "$AOAI_ID"
  green "Role assigned"
else
  yellow "Role already present (skip)"
fi

# ============================================================
# Step 3 — Backends: aoai-sea, embeddings-backend, slm-phi4
#         (use az rest because az apim backend create has no
#          flag for circuit breaker — we always go via PUT)
# ============================================================
echo "[3/7] Create backends..."

put_backend() {
  local backend_id="$1" body_file="$2"
  run az rest --method put \
    --url "${MGMT}/backends/${backend_id}?api-version=${API_VER}" \
    --body "@${body_file}" \
    --headers Content-Type=application/json >/dev/null
}

# aoai-sea — with circuit breaker (Step 5 baked in here)
cat > /tmp/be-aoai.json <<JSON
{
  "properties": {
    "url": "${AOAI_ENDPOINT}/openai",
    "protocol": "http",
    "credentials": { "managedIdentity": { "resource": "https://cognitiveservices.azure.com" } },
    "circuitBreaker": {
      "rules": [{
        "name": "aoai-trip-on-429-or-5xx",
        "failureCondition": {
          "count": 5,
          "interval": "PT1M",
          "statusCodeRanges": [
            { "min": 429, "max": 429 },
            { "min": 500, "max": 599 }
          ]
        },
        "tripDuration": "PT5M",
        "acceptRetryAfter": true
      }]
    }
  }
}
JSON
put_backend aoai-sea /tmp/be-aoai.json
green "Backend aoai-sea (with circuit breaker)"

# embeddings-backend — MI auth REQUIRED by llm-semantic-cache-lookup schema
cat > /tmp/be-emb.json <<JSON
{
  "properties": {
    "url": "${AOAI_ENDPOINT}/openai/deployments/text-embedding-3-large",
    "protocol": "http",
    "credentials": { "managedIdentity": { "resource": "https://cognitiveservices.azure.com" } }
  }
}
JSON
put_backend embeddings-backend /tmp/be-emb.json
green "Backend embeddings-backend"

# slm-phi4 — internal LB IP (only if the service exists; soft-fail otherwise).
# SLM_PRESENT drives whether the priority pool below includes slm-phi4 — the
# pool creation must not reference a backend that wasn't created.
SLM_IP=$(kubectl get svc slm-phi4 -n slm \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
SLM_PRESENT=0
if [[ -n "$SLM_IP" ]]; then
  cat > /tmp/be-slm.json <<JSON
{
  "properties": {
    "url": "http://${SLM_IP}:8000/v1",
    "protocol": "http"
  }
}
JSON
  put_backend slm-phi4 /tmp/be-slm.json
  green "Backend slm-phi4 (http://${SLM_IP}:8000/v1)"
  SLM_PRESENT=1
else
  yellow "slm-phi4 service not deployed (skip — header routing will 502 until deployed)"
fi

# ============================================================
# Step 4 — Backend Pool aoai-pool (P1=aoai-sea, P2=slm-phi4 when present)
# ============================================================
echo "[4/7] Create priority backend pool aoai-pool..."
POOL_SERVICES="[{ \"id\": \"/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}/backends/aoai-sea\", \"priority\": 1, \"weight\": 100 }"
if (( SLM_PRESENT == 1 )); then
  POOL_SERVICES="${POOL_SERVICES}, { \"id\": \"/subscriptions/${SUB_ID}/resourceGroups/${RG}/providers/Microsoft.ApiManagement/service/${APIM}/backends/slm-phi4\", \"priority\": 2, \"weight\": 100 }"
fi
POOL_SERVICES="${POOL_SERVICES}]"
cat > /tmp/be-pool.json <<JSON
{
  "properties": {
    "type": "Pool",
    "pool": { "services": ${POOL_SERVICES} }
  }
}
JSON
put_backend aoai-pool /tmp/be-pool.json
if (( SLM_PRESENT == 1 )); then
  green "Pool aoai-pool (P1=aoai-sea, P2=slm-phi4)"
else
  green "Pool aoai-pool (P1=aoai-sea only — SLM skipped)"
fi

# ============================================================
# Step 5 — Content Safety backend (optional)
# ============================================================
if (( WITH_CS == 1 )); then
  echo "[5/7] Content Safety backend (--with-content-safety)..."
  # Prefer CONTENT_SAFETY_NAME env var, then fall back to the Terraform
  # output `content_safety_name` (set when `deploy_content_safety = true`
  # in infra/modules/aoai-singapore). The output may be an empty string
  # if the operator opted out; in that case we soft-skip with a hint.
  CS_NAME="${CONTENT_SAFETY_NAME:-}"
  if [[ -z "$CS_NAME" ]]; then
    CS_NAME=$(terraform -chdir="$INFRA_DIR" output -raw content_safety_name 2>/dev/null || true)
  fi
  if [[ -z "$CS_NAME" ]]; then
    yellow "Content Safety account not deployed (Terraform output 'content_safety_name' empty AND \$CONTENT_SAFETY_NAME unset). Either set deploy_content_safety=true in infra/ and re-apply, or export CONTENT_SAFETY_NAME=<existing-cs-account>. Skipping."
  else
    CS_ID=$(az cognitiveservices account show -g "$RG" -n "$CS_NAME" --query id -o tsv 2>/dev/null || true)
    if [[ -z "$CS_ID" ]]; then
      yellow "Content Safety account '$CS_NAME' not found in RG '$RG' — skipping"
    else
      CS_EP=$(az cognitiveservices account show -g "$RG" -n "$CS_NAME" --query properties.endpoint -o tsv)
      CS_RA=$(az role assignment list --assignee-object-id "$APIM_MI" --scope "$CS_ID" \
              --query "[?roleDefinitionName=='Cognitive Services User'] | length(@)" -o tsv 2>/dev/null || echo 0)
      [[ "$CS_RA" == "0" ]] && run az role assignment create --assignee-object-id "$APIM_MI" \
        --assignee-principal-type ServicePrincipal --role 'Cognitive Services User' --scope "$CS_ID"
      cat > /tmp/be-cs.json <<JSON
{
  "properties": {
    "url": "${CS_EP}",
    "protocol": "http",
    "credentials": { "managedIdentity": { "resource": "https://cognitiveservices.azure.com" } }
  }
}
JSON
      put_backend content-safety-sea /tmp/be-cs.json
      green "Backend content-safety-sea"
    fi
  fi
else
  yellow "[5/7] Content Safety SKIPPED (use --with-content-safety to enable)"
fi

# ============================================================
# Step 6 — App Insights diagnostic (metrics:true) on the openai API
# ============================================================
echo "[6/7] Wire App Insights diagnostic on api/openai (metrics:true)..."
# `az apim logger list` is not exposed in the Azure CLI surface today —
# hit the management API instead.
LOGGER_ID=$(az rest --method get \
  --url "${MGMT}/loggers?api-version=${API_VER}" \
  --query "value[?properties.loggerType=='applicationInsights'] | [0].id" \
  -o tsv 2>/dev/null || true)
if [[ -z "$LOGGER_ID" ]]; then
  yellow "No App Insights logger found on the APIM service. Create one (Terraform should do this)."
else
  cat > /tmp/diag.json <<JSON
{
  "properties": {
    "loggerId": "${LOGGER_ID}",
    "sampling":  { "samplingType": "fixed", "percentage": 100 },
    "alwaysLog": "allErrors",
    "logClientIp": true,
    "metrics":   true,
    "verbosity": "information",
    "httpCorrelationProtocol": "W3C",
    "frontend": { "request":  { "headers": [], "body": { "bytes": 0 } },
                  "response": { "headers": [], "body": { "bytes": 0 } } },
    "backend":  { "request":  { "headers": [], "body": { "bytes": 0 } },
                  "response": { "headers": [], "body": { "bytes": 0 } } }
  }
}
JSON
  run az rest --method put \
    --url "${MGMT}/apis/openai/diagnostics/applicationinsights?api-version=${API_VER}" \
    --body @/tmp/diag.json --headers Content-Type=application/json >/dev/null
  green "App Insights diagnostic enabled (metrics:true)"
fi

# ============================================================
# Step 7 — Push the policy XML
# ============================================================
echo "[7/7] Push policy bundle..."
POLICY_FILE="$POLICIES_DIR/workshop-llm-policy.xml"
[[ -f "$POLICY_FILE" ]] || { echo "missing $POLICY_FILE"; exit 1; }

# Build the final XML (start from base bundle, optionally weave in extras)
WORK=/tmp/policy-final.xml
cp "$POLICY_FILE" "$WORK"

# When --with-content-safety was NOT passed the `content-safety-sea` backend
# does not exist and the <llm-content-safety> block makes APIM reject the
# whole policy with `Backend with id 'content-safety-sea' could not be found`.
# Strip the block in that case — the base bundle stays the source of truth,
# this just makes default runs work.
if (( WITH_CS == 0 )); then
  echo "  - stripping <llm-content-safety> block (no --with-content-safety)"
  if (( DRY == 0 )); then
    python3 - "$WORK" <<'PY'
import re, sys
p = sys.argv[1]
src = open(p, encoding="utf-8").read()
# Drop the policy element plus the immediately-preceding `<!-- ... -->`
# comment so we don't leave an orphan comment behind.
pattern = re.compile(
    r"\n[ \t]*(?:<!--[^\n]*?-->\s*)?<llm-content-safety[\s\S]*?</llm-content-safety>\s*",
    re.MULTILINE,
)
open(p, "w", encoding="utf-8").write(pattern.sub("\n", src))
PY
  fi
fi

if (( WITH_QUOTA == 1 )); then
  echo "  + folding in quota-by-key-monthly.xml"
  if (( DRY == 0 )); then
    QUOTA_XML=$(cat "$POLICIES_DIR/quota-by-key-monthly.xml")
    # Insert just before the closing </inbound>
    awk -v ins="$QUOTA_XML" '
      /<\/inbound>/ && !done { print ins; done=1 } { print }
    ' "$WORK" > "${WORK}.tmp" && mv "${WORK}.tmp" "$WORK"
  fi
fi

if (( WITH_PII == 1 )); then
  echo "  + folding in pii-mask-outbound.xml"
  if (( DRY == 0 )); then
    PII_XML=$(sed -n '/<outbound>/,/<\/outbound>/p' "$POLICIES_DIR/pii-mask-outbound.xml" \
      | sed -e 's|<outbound>||' -e 's|</outbound>||')
    awk -v ins="$PII_XML" '
      /<\/outbound>/ && !done { print ins; done=1 } { print }
    ' "$WORK" > "${WORK}.tmp" && mv "${WORK}.tmp" "$WORK"
  fi
fi

if (( WITH_AUDIT == 1 )); then
  : "${EH_NAMESPACE:?--with-audit requires EH_NAMESPACE}"
  : "${EH_HUB_NAME:?--with-audit requires EH_HUB_NAME}"
  : "${EH_CONNSTR:?--with-audit requires EH_CONNSTR (Send-only SAS)}"
  echo "  + creating audit Event Hub logger..."
  cat > /tmp/eh-logger.json <<JSON
{
  "properties": {
    "loggerType": "azureEventHub",
    "description": "BFSI immutable audit trail",
    "credentials": { "name": "${EH_HUB_NAME}", "connectionString": "${EH_CONNSTR}" }
  }
}
JSON
  run az rest --method put \
    --url "${MGMT}/loggers/audit-eventhub-logger?api-version=${API_VER}" \
    --body @/tmp/eh-logger.json --headers Content-Type=application/json >/dev/null
  echo "  + folding in audit-trail-eventhub.xml"
  if (( DRY == 0 )); then
    AUDIT_INBOUND=$(sed -n '/<inbound>/,/<\/inbound>/p' "$POLICIES_DIR/audit-trail-eventhub.xml" | sed -e 's|<inbound>||' -e 's|</inbound>||')
    AUDIT_OUTBOUND=$(sed -n '/<outbound>/,/<\/outbound>/p' "$POLICIES_DIR/audit-trail-eventhub.xml" | sed -e 's|<outbound>||' -e 's|</outbound>||')
    AUDIT_ONERR=$(sed -n '/<on-error>/,/<\/on-error>/p' "$POLICIES_DIR/audit-trail-eventhub.xml" | sed -e 's|<on-error>||' -e 's|</on-error>||')
    awk -v i="$AUDIT_INBOUND" -v o="$AUDIT_OUTBOUND" -v e="$AUDIT_ONERR" '
      /<\/inbound>/ && !i_done { print i; i_done=1 }
      /<\/outbound>/ && !o_done { print o; o_done=1 }
      /<\/on-error>/ && !e_done { print e; e_done=1 }
      { print }
    ' "$WORK" > "${WORK}.tmp" && mv "${WORK}.tmp" "$WORK"
  fi
fi

# Push as rawxml. Escaping JSON requires we wrap value carefully.
if (( DRY == 0 )); then
  # jq -Rs reads the whole file as one JSON string (handles quotes, newlines).
  jq -n --arg val "$(cat "$WORK")" \
     '{properties: {format: "rawxml", value: $val}}' > /tmp/policy-put.json
fi
run az rest --method put \
  --url "${MGMT}/apis/openai/policies/policy?api-version=${API_VER}" \
  --body @/tmp/policy-put.json --headers Content-Type=application/json >/dev/null
green "Policy bundle pushed to api/openai"

echo ""
echo "=== Done ==="
echo "Verify with:"
echo "  export APIM_GATEWAY_URL=\$(terraform -chdir=$INFRA_DIR output -raw apim_gateway_url)"
echo "  export APIM_KEY=\$(az apim subscription show -g $RG --service-name $APIM --sid attendee-01 --query primaryKey -o tsv)"
echo "  ./scripts/verify-policies.sh --m2"
