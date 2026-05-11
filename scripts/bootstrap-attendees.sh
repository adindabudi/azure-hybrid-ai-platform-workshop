#!/usr/bin/env bash
# Bootstrap per-attendee namespaces, RBAC, ResourceQuota, ServiceAccount, and
# SecretProviderClass after `terraform apply` of the landing zone has succeeded.
#
# Usage:
#   ./scripts/bootstrap-attendees.sh
#
# Requires: kubectl, az, jq, terraform CLIs available locally.

set -euo pipefail

INFRA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../infra" && pwd)"
cd "$INFRA_DIR"

echo "==> Reading Terraform outputs..."
RG=$(terraform output -raw resource_group_name)
AKS=$(terraform output -raw aks_name)
KV_URI=$(terraform output -raw key_vault_uri)
AOAI_ENDPOINT=$(terraform output -raw aoai_endpoint)
APIM_GATEWAY=$(terraform output -raw apim_gateway_url)

KV_NAME=$(echo "$KV_URI" | sed -E 's|https://([^.]+)\..*|\1|')
TENANT_ID=$(az account show --query tenantId -o tsv)

echo "==> Fetching AKS credentials..."
az aks get-credentials -g "$RG" -n "$AKS" --overwrite-existing >/dev/null

echo "==> Reading attendee handout (sensitive)..."
HANDOUT_JSON=$(terraform output -json attendee_handout)
ATTENDEES=$(echo "$HANDOUT_JSON" | jq -r 'keys[]' | sort)

# Attendee UAMI client IDs — pulled from the AKS module's generated identities.
UAMI_MAP=$(az identity list -g "$RG" --query "[?starts_with(name, 'uami-attendee-')].{ns: name, clientId: clientId}" -o json)

# ----- Optional: seed shared secrets in KV -----
echo "==> Seeding shared secrets in Key Vault $KV_NAME..."
declare -A KV_SEEDS=(
  ["aoai-endpoint"]="$AOAI_ENDPOINT"
  ["apim-gateway-url"]="$APIM_GATEWAY"
)
for k in "${!KV_SEEDS[@]}"; do
  az keyvault secret set --vault-name "$KV_NAME" --name "$k" --value "${KV_SEEDS[$k]}" >/dev/null
  echo "    kv://${KV_NAME}/${k} set"
done

echo "==> Per-attendee namespace bootstrap..."
for NS in $ATTENDEES; do
  echo ""
  echo "----- $NS -----"

  # Pull attendee-specific bits from terraform handout.
  APIM_SUB_ID=$(echo "$HANDOUT_JSON" | jq -r ".\"$NS\".apim_subscription_id")
  UAMI_CLIENT_ID=$(echo "$UAMI_MAP" | jq -r ".[] | select(.ns==\"uami-${NS}\") | .clientId")

  if [[ -z "$UAMI_CLIENT_ID" || "$UAMI_CLIENT_ID" == "null" ]]; then
    echo "    !! UAMI for $NS not found, skipping"
    continue
  fi

  # Subscription key (sensitive, fetch JIT).
  APIM_NAME=$(terraform output -raw apim_name)
  APIM_KEY=$(az apim subscription show \
    --resource-group "$RG" --service-name "$APIM_NAME" \
    --sid "${NS}" --query primaryKey -o tsv 2>/dev/null \
    || az rest --method post \
        --url "${APIM_SUB_ID}/listSecrets?api-version=2022-08-01" \
        --query primaryKey -o tsv)

  # Namespace
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  # ResourceQuota: 4 vCPU / 8Gi memory per attendee — keeps a single AKS shared.
  kubectl apply -n "$NS" -f - <<YAML
apiVersion: v1
kind: ResourceQuota
metadata:
  name: attendee-quota
spec:
  hard:
    requests.cpu: "4"
    requests.memory: "8Gi"
    limits.cpu: "8"
    limits.memory: "16Gi"
    pods: "30"
    services.loadbalancers: "0"
YAML

  # LimitRange: default container requests if pod author forgets.
  kubectl apply -n "$NS" -f - <<YAML
apiVersion: v1
kind: LimitRange
metadata:
  name: attendee-limits
spec:
  limits:
    - default:
        cpu: 500m
        memory: 512Mi
      defaultRequest:
        cpu: 100m
        memory: 128Mi
      type: Container
YAML

  # ServiceAccount with workload identity annotations.
  kubectl apply -n "$NS" -f - <<YAML
apiVersion: v1
kind: ServiceAccount
metadata:
  name: agent-sa
  annotations:
    azure.workload.identity/client-id: "${UAMI_CLIENT_ID}"
  labels:
    azure.workload.identity/use: "true"
YAML

  # SecretProviderClass (Azure Key Vault CSI) — workload identity mode.
  kubectl apply -n "$NS" -f - <<YAML
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: azure-kv-shared
spec:
  provider: azure
  parameters:
    usePodIdentity: "false"
    useVMManagedIdentity: "false"
    clientID: "${UAMI_CLIENT_ID}"
    keyvaultName: "${KV_NAME}"
    tenantId: "${TENANT_ID}"
    objects: |
      array:
        - |
          objectName: aoai-endpoint
          objectType: secret
        - |
          objectName: apim-gateway-url
          objectType: secret
  secretObjects:
    - secretName: workshop-shared
      type: Opaque
      data:
        - objectName: aoai-endpoint
          key: aoai-endpoint
        - objectName: apim-gateway-url
          key: apim-gateway-url
YAML

  # Per-attendee APIM key — stored as a regular k8s Secret (NOT in KV; rotated per-workshop).
  kubectl create secret generic apim-credentials \
    --namespace "$NS" \
    --from-literal=subscription-key="${APIM_KEY:-not-fetched}" \
    --dry-run=client -o yaml | kubectl apply -f - >/dev/null

  echo "    namespace=$NS  uami=${UAMI_CLIENT_ID:0:8}...  kv=${KV_NAME}  apim=ok"
done

echo ""
echo "==> Done. Verify with:"
echo "    kubectl get ns | grep attendee"
echo "    kubectl get serviceaccount,secretproviderclass,secret -n attendee-01"
